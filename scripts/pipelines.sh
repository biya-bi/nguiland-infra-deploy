#!/usr/bin/env bash

set -euo pipefail

pipelines_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pipelines_manifest_dir="${pipelines_dir}/../kubernetes/pipelines"

. "${pipelines_dir}/yq.sh"
. "${pipelines_dir}/wait-k8s-resource.sh"

wait_for_pipeline_exists() {
  wait_for_resource "${1}" "pipeline" "${2}" "exists" "${3:-10m}"
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
  local relative_path="${2}"
  local param_setter_func="${3:-}"

  local manifest_path
  manifest_path=$(copy_pipelinerun_manifest "${relative_path}")
  # File created; ensure it is cleaned up even if subsequent steps fail
  trap 'rm -f -- "${manifest_path}"' RETURN

  if [[ -n "${param_setter_func}" ]]; then
    "${param_setter_func}" "${namespace}" "${manifest_path}"
  fi

  echo "Applying PipelineRun manifest: ${manifest_path}"

  local pipelinerun_name
  pipelinerun_name=$(kubectl create -f "${manifest_path}" -o jsonpath='{.metadata.name}')
  echo "Triggered PipelineRun ${pipelinerun_name}"

  wait_for_pipelinerun_completion "${namespace}" "${pipelinerun_name}" "1h"
}

run_docker_build_pipeline() {
  local namespace="${1}"
  local relative_path="${2}"
  run_pipeline "${namespace}" "${relative_path}" "set_docker_build_pipeline_params"
}

run_oci_publish_pipeline() {
  local namespace="${1}"
  local relative_path="${2}"
  run_pipeline "${namespace}" "${relative_path}" "set_oci_publish_pipeline_params"
}

get_pipeline_name() {
  local relative_path="${1}"
  local manifest_path="${pipelines_manifest_dir}/${relative_path}"

  if [[ ! -f "${manifest_path}" ]]; then
    echo "Pipeline manifest not found: ${manifest_path}" >&2
    return 1
  fi

  yq_r ".spec.pipelineRef.name" "${manifest_path}"
}
