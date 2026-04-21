#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pipelines_manifest_dir="${script_dir}/../kubernetes/pipelines"

cleanup_terminal() {
  printf '\033[?25h'
}
trap cleanup_terminal EXIT
trap 'exit 130' INT

# Portable yq in-place edit function to handle both mikefarah/yq (Go) and kislyuk/yq (Python)
yq_i() {
  local expression="$1"
  local file="$2"

  if yq --version 2>&1 | grep -q "mikefarah"; then
    yq -i "${expression}" "${file}"
  else
    yq -yi "${expression}" "${file}"
  fi
}

# Convert a duration string into seconds.
timeout_to_seconds() {
  local timeout="${1}"

  if [[ "${timeout}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${timeout}" =~ ^([0-9]+)m$ ]]; then
    echo "$((${BASH_REMATCH[1]} * 60))"
  elif [[ "${timeout}" =~ ^([0-9]+)h$ ]]; then
    echo "$((${BASH_REMATCH[1]} * 3600))"
  elif [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    echo "${timeout}"
  else
    echo "600"
  fi
}

get_wait_message() {
  local resource_type="$1"
  local resource_name="$2"
  local condition="$3"
  local namespace="$4"

  if [[ "${condition}" == "exists" ]]; then
    printf "Waiting for %s/%s to exist in namespace %s" "${resource_type}" "${resource_name}" "${namespace}"
  elif [[ "${condition}" == condition=* ]]; then
    local condition_value=${condition#condition=}
    local condition_text
    condition_text=$(printf "%s" "${condition_value}" | tr '[:upper:]' '[:lower:]')

    if [[ "${condition_text}" =~ ed$ ]]; then
      local condition_verb=${condition_text%ed}
      printf "Waiting for %s/%s to %s in namespace %s" "${resource_type}" "${resource_name}" "${condition_verb}" "${namespace}"
    else
      printf "Waiting for %s/%s to be %s in namespace %s" "${resource_type}" "${resource_name}" "${condition_text}" "${namespace}"
    fi
  else
    printf "Waiting for %s/%s %s in namespace %s" "${resource_type}" "${resource_name}" "${condition}" "${namespace}"
  fi
}

wait_for_resource() {
  local namespace="$1"
  local resource_type="$2"
  local resource_name="$3"
  local condition="$4"
  local failure_condition=""
  local timeout=""

  if [[ -n "${6:-}" ]]; then
    failure_condition="${5}"
    timeout="${6:-10m}"
  else
    timeout="${5:-10m}"
  fi

  local timeout_in_seconds
  timeout_in_seconds=$(timeout_to_seconds "${timeout}")
  local deadline
  deadline=$(($(date +%s) + timeout_in_seconds))
  local dots=0
  local dot_states=("   " ".  " ".. " "...")

  local message
  message=$(get_wait_message "${resource_type}" "${resource_name}" "${condition}" "${namespace}")
  printf "%s" "${message}"
  printf '\033[?25l'

  while true; do
    if [[ "${condition}" == "exists" ]]; then
      if kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" >/dev/null 2>&1; then
        printf "\n"
        return 0
      fi
    else
      if kubectl wait --for="${condition}" "${resource_type}/${resource_name}" -n "${namespace}" --timeout=5s >/dev/null 2>&1; then
        printf "\n"
        return 0
      fi
    fi

    # Fail-fast: Check if the pod is in a bad state
    if [[ "${resource_type}" == "deployment" || "${resource_type}" == "pod" ]]; then
      local status_json
      status_json=$(kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o json 2>/dev/null || echo "{}")
      if echo "${status_json}" | jq -e '.status.containerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "Error")' >/dev/null 2>&1; then
        printf "\n\033[0;31mERROR: %s/%s entered a terminal failure state (CrashLoopBackOff/Error).\033[0m\n" "${resource_type}" "${resource_name}"
        kubectl logs -n "${namespace}" "${resource_type}/${resource_name}" --all-containers --tail=20 || true
        return 1
      fi
    fi

    if [[ -n "${failure_condition}" ]]; then
      if kubectl wait --for="${failure_condition}" "${resource_type}/${resource_name}" -n "${namespace}" --timeout=5s >/dev/null 2>&1; then
        printf "\n"
        return 1
      fi
    fi

    if (( $(date +%s) >= deadline )); then
      printf "\n"
      return 1
    fi

    dots=$(( (dots + 1) % 4 ))
    printf "\r%s%s" "${message}" "${dot_states[dots]}"
    sleep 5
  done
}

wait_for_deployment_available() {
  wait_for_resource "${1}" "deployment" "${2}" "condition=Available" "${3:-10m}"
}

wait_for_helmrepository_exists() {
  wait_for_resource "${1}" "helmrepository" "${2}" "exists" "${3:-10m}"
}

wait_for_helmrelease_exists() {
  wait_for_resource "${1}" "helmrelease" "${2}" "exists" "${3:-10m}"
}

wait_for_pipeline_exists() {
  wait_for_resource "${1}" "pipeline" "${2}" "exists" "${3:-10m}"
}

suspend_helmreleases() {
  local namespace="${1}"
  shift
  local release_names=("${@}")

  for release_name in "${release_names[@]}"; do
    wait_for_helmrelease_exists "${namespace}" "${release_name}" "10m"
    flux suspend hr "${release_name}" -n "${namespace}"
  done
}

wait_for_helmrelease() {
  wait_for_resource "${1}" "helmrelease" "${2}" "condition=Ready" "${3:-5m}"
}

resume_helmreleases() {
  local namespace="${1}"
  shift
  local release_names=("${@}")

  for release_name in "${release_names[@]}"; do
    flux resume hr "${release_name}" -n "${namespace}"
  done
}

copy_pipelinerun_manifest() {
  local relative_path="${1}"

  if [[ -z "${relative_path}" ]]; then
    echo "Relative PipelineRun manifest path must be provided" >&2
    return 1
  fi

  local manifest_path="${pipelines_manifest_dir}/${relative_path}"

  if [[ ! -f "${manifest_path}" ]]; then
    echo "PipelineRun manifest not found: ${manifest_path}" >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp)
  cp "${manifest_path}" "${tmp_file}"

  echo "${tmp_file}"
}

set_docker_build_pipeline_params() {
  local namespace="${1}"
  local manifest_path="${2}"

  if [[ -z "${namespace}" || -z "${manifest_path}" ]]; then
    echo "Namespace and PipelineRun manifest path must be provided" >&2
    return 1
  fi

  local image_push_endpoint
  image_push_endpoint=$(kubectl get configmap env-settings -n "${namespace}" -o jsonpath='{.data.image-push-endpoint}' 2>/dev/null || true)

  if [[ -z "${image_push_endpoint}" ]]; then
    echo "Failed to retrieve image-push-endpoint from env-settings ConfigMap in namespace ${namespace}" >&2
    return 1
  fi

  printf "Setting image-push-endpoint to %s in manifest %s\n" "${image_push_endpoint}" "${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"image-push-endpoint\")).value = \"${image_push_endpoint}\"" "${manifest_path}"
  printf "Setting always-build to true in manifest %s\n" "${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"always-build\")).value = \"true\"" "${manifest_path}"
}

set_oci_publish_pipeline_params() {
  local namespace="${1}"
  local manifest_path="${2}"

  if [[ -z "${namespace}" || -z "${manifest_path}" ]]; then
    echo "Namespace and PipelineRun manifest path must be provided" >&2
    return 1
  fi

  local helm_repo_json
  helm_repo_json=$(kubectl get helmrepository artifactory-oci -n "${namespace}" -o json 2>/dev/null || echo "{}")
  local insecure_status
  insecure_status=$(echo "${helm_repo_json}" | jq -r '.spec.insecure // "false"')
  local helm_registry_url
  helm_registry_url=$(echo "${helm_repo_json}" | jq -r '.spec.url // ""')
  local skip_tls="false"
  local lower_insecure_status
  lower_insecure_status=$(echo "${insecure_status}" | tr '[:upper:]' '[:lower:]')

  printf "Retrieved URL from HelmRepository artifactory-oci: %s\n" "${helm_registry_url:-<missing>}"

  if [[ "${lower_insecure_status}" == "true" ]]; then
    skip_tls="true"
  fi

  printf "Setting skipTls to %s based on artifactory-oci HelmRepository insecure status: %s in manifest %s\n" "${skip_tls}" "${insecure_status:-<missing>}" "${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"skipTls\")).value = \"${skip_tls}\"" "${manifest_path}"

  if [[ -n "${helm_registry_url}" ]]; then
    local registry_suffix="org.nguiland.infra"
    local normalized_registry_url="${helm_registry_url%/}"

    if [[ "${normalized_registry_url}" != "${registry_suffix}" && "${normalized_registry_url}" != */${registry_suffix} ]]; then
      normalized_registry_url="${normalized_registry_url}/${registry_suffix}"
    fi

    helm_registry_url="${normalized_registry_url}"
    printf "Setting helm-registry to %s based on artifactory-oci HelmRepository URL: %s in manifest %s\n" "${helm_registry_url}" "${helm_registry_url}" "${manifest_path}"
    yq_i "(.spec.params[] | select(.name == \"helm-registry\")).value = \"${helm_registry_url}\"" "${manifest_path}"
  fi
}

wait_for_pipelinerun_completion() {
  local namespace="${1}"
  local pipelinerun_name="${2}"
  local timeout="${3:-1h}"

  if wait_for_resource "${namespace}" "pipelinerun" "${pipelinerun_name}" "condition=Succeeded" "condition=Succeeded=False" "${timeout}"; then
    echo "PipelineRun ${pipelinerun_name} succeeded"
    return 0
  fi

  printf '\033[31mPipelineRun %s failed or timed out\033[0m\n' "${pipelinerun_name}" >&2
  kubectl describe pipelinerun "${pipelinerun_name}" -n "${namespace}" || true
  return 1
}

run_pipeline() {
  local namespace="${1}"
  local manifest_path="${2}"

  echo "Applying PipelineRun manifest: ${manifest_path}"
  trap "rm -f -- '${manifest_path}'" RETURN

  local pipelinerun_name
  pipelinerun_name=$(kubectl create -f "${manifest_path}" -o jsonpath='{.metadata.name}')
  echo "Triggered PipelineRun ${pipelinerun_name}"

  wait_for_pipelinerun_completion "${namespace}" "${pipelinerun_name}" "1h"
}

run_docker_build_pipeline() {
  local namespace="${1}"
  local relative_path="${2}"

  local manifest_path
  manifest_path=$(copy_pipelinerun_manifest "${relative_path}")
  set_docker_build_pipeline_params "${namespace}" "${manifest_path}"
  run_pipeline "${namespace}" "${manifest_path}"
}

run_oci_publish_pipeline() {
  local namespace="${1}"
  local relative_path="${2}"

  local manifest_path
  manifest_path=$(copy_pipelinerun_manifest "${relative_path}")
  set_oci_publish_pipeline_params "${namespace}" "${manifest_path}"
  run_pipeline "${namespace}" "${manifest_path}"
}

get_artifactory_addons() {
  local namespace="${1}"

  kubectl get helmrelease -n "${namespace}" -o json | jq -r '
    .items[] |
    select(
      .spec.dependsOn // [] |
      any(.name == "artifactory-jcr" or .name == "artifactory-oss")
    ) |
    .metadata.name
  '
}

get_pipeline_name() {
  local relative_path="${1}"
  local manifest_path="${pipelines_manifest_dir}/${relative_path}"

  if [[ ! -f "${manifest_path}" ]]; then
    echo "Pipeline manifest not found: ${manifest_path}" >&2
    return 1
  fi

  if yq --version 2>&1 | grep -q "mikefarah"; then
    yq '.spec.pipelineRef.name' "${manifest_path}"
  else
    yq -r '.spec.pipelineRef.name' "${manifest_path}"
  fi
}

main() {
  local namespace="infra"

  local addons=()
  while IFS= read -r line; do
    addons+=("$line")
  done < <(get_artifactory_addons "${namespace}")

  suspend_helmreleases "${namespace}" "${addons[@]}"
  wait_for_deployment_available "${namespace}" "artifactory-jcr" "15m"

  local docker_build_manifest_path="infra/docker/build.yaml"
  local oci_publish_manifest_path="infra/oci/publish.yaml"

  local pipeline_manifest_paths=()
  pipeline_manifest_paths+=("${docker_build_manifest_path}")
  pipeline_manifest_paths+=("${oci_publish_manifest_path}")

  local pipeline_name
  for relative_path in "${pipeline_manifest_paths[@]}"; do
    pipeline_name=$(get_pipeline_name "$relative_path")
    wait_for_pipeline_exists "${namespace}" "${pipeline_name}" "15m"
  done

  run_docker_build_pipeline "${namespace}" "$docker_build_manifest_path"
  run_oci_publish_pipeline "${namespace}" "$oci_publish_manifest_path"
  wait_for_helmrepository_exists "${namespace}" "artifactory-oci" "10m"
  resume_helmreleases "${namespace}" "${addons[@]}"
}

# Direct-execution guard: only invoke main when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
