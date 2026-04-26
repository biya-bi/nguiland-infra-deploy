#!/usr/bin/env bash

set -euo pipefail

pipelines_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pipelines_manifest_dir="${pipelines_dir}/../kubernetes/pipelines"

. "${pipelines_dir}/logger.sh"
. "${pipelines_dir}/yq.sh"
. "${pipelines_dir}/wait-k8s-resource.sh"

wait_for_pipeline_exists() {
  wait_for_resource "${1}" "pipeline" "${2}" "exists" "${3:-10m}"
}

copy_pipelinerun_manifest() {
  local relative_path="${1}"

  if [[ -z "${relative_path}" ]]; then
    log_error "Relative PipelineRun manifest path must be provided"
    return 1
  fi

  local manifest_path="${pipelines_manifest_dir}/${relative_path}"

  if [[ ! -f "${manifest_path}" ]]; then
    log_error "PipelineRun manifest not found: ${manifest_path}"
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
    log_error "Namespace and PipelineRun manifest path must be provided"
    return 1
  fi

  local image_push_endpoint
  image_push_endpoint=$(kubectl get configmap env-settings -n "${namespace}" -o jsonpath='{.data.image-push-endpoint}' 2>/dev/null || true)

  if [[ -z "${image_push_endpoint}" ]]; then
    log_error "Failed to retrieve image-push-endpoint from env-settings ConfigMap in namespace ${namespace}"
    return 1
  fi

  log_info "Setting image-push-endpoint to ${image_push_endpoint} in manifest ${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"image-push-endpoint\")).value = \"${image_push_endpoint}\"" "${manifest_path}"
  log_info "Setting always-build to true in manifest ${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"always-build\")).value = \"true\"" "${manifest_path}"
}

set_oci_publish_pipeline_params() {
  local namespace="${1}"
  local manifest_path="${2}"

  if [[ -z "${namespace}" || -z "${manifest_path}" ]]; then
    log_error "Namespace and PipelineRun manifest path must be provided"
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

  log_info "Retrieved URL from HelmRepository artifactory-oci: ${helm_registry_url:-<missing>}"

  if [[ "${lower_insecure_status}" == "true" ]]; then
    skip_tls="true"
  fi

  log_info "Setting skipTls to ${skip_tls} based on artifactory-oci HelmRepository insecure status: ${insecure_status:-<missing>} in manifest ${manifest_path}"
  yq_i "(.spec.params[] | select(.name == \"skipTls\")).value = \"${skip_tls}\"" "${manifest_path}"

  if [[ -n "${helm_registry_url}" ]]; then
    local registry_suffix="org.nguiland.infra"
    local normalized_registry_url="${helm_registry_url%/}"

    if [[ "${normalized_registry_url}" != "${registry_suffix}" && "${normalized_registry_url}" != */${registry_suffix} ]]; then
      normalized_registry_url="${normalized_registry_url}/${registry_suffix}"
    fi

    helm_registry_url="${normalized_registry_url}"
    log_info "Setting helm-registry to ${helm_registry_url} based on artifactory-oci HelmRepository URL in manifest ${manifest_path}"
    yq_i "(.spec.params[] | select(.name == \"helm-registry\")).value = \"${helm_registry_url}\"" "${manifest_path}"
  fi
}

wait_for_pipelinerun_completion() {
  local namespace="${1}"
  local pipelinerun_name="${2}"
  local timeout="${3:-1h}"

  if wait_for_resource "${namespace}" "pipelinerun" "${pipelinerun_name}" "condition=Succeeded" "condition=Succeeded=False" "${timeout}"; then
    log_info "PipelineRun ${pipelinerun_name} succeeded"
    return 0
  fi

  log_error "PipelineRun ${pipelinerun_name} failed or timed out"
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
  trap "rm -f -- '${manifest_path}'" RETURN

  if [[ -n "${param_setter_func}" ]]; then
    "${param_setter_func}" "${namespace}" "${manifest_path}"
  fi

  log_info "Applying PipelineRun manifest: ${manifest_path}"

  local pipelinerun_name
  pipelinerun_name=$(kubectl create -f "${manifest_path}" -o jsonpath='{.metadata.name}')
  log_info "Triggered PipelineRun ${pipelinerun_name}"

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
    log_error "Pipeline manifest not found: ${manifest_path}"
    return 1
  fi

  yq_r ".spec.pipelineRef.name" "${manifest_path}"
}
