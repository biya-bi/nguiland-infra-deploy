#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pipelines_manifest_dir="${scripts_dir}/../kubernetes/pipelines"

. "${scripts_dir}/logger.sh"
. "${scripts_dir}/yq.sh"
. "${scripts_dir}/wait-k8s-resource.sh"

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

get_artifactory_oci_resource() {
  kubectl get helmrepository artifactory-oci -n "${1}" -o json 2>/dev/null || echo "{}"
}

set_pipeline_param() {
  local name="${1}"
  local value="${2}"
  local manifest_path="${3}"

  log_info "Setting ${name} to ${value} in manifest ${manifest_path}"
  yq_i ".spec.params |= (map(select(.name != \"${name}\")) + [{\"name\": \"${name}\", \"value\": \"${value}\"}])" "${manifest_path}"
}

get_image_push_endpoint() {
  local namespace="${1}"
  local image_push_endpoint
  local image_push_port

  image_push_endpoint=$(kubectl get configmap cluster-settings -n "${namespace}" -o jsonpath='{.data.ACTIFACTORY_JCR_HOST}' 2>/dev/null || echo "")
  image_push_port=$(kubectl get configmap cluster-settings -n "${namespace}" -o jsonpath='{.data.ACTIFACTORY_JCR_PORT}' 2>/dev/null || echo "")

  if [[ -z "${image_push_endpoint}" ]]; then
    log_error "Failed to retrieve ACTIFACTORY_JCR_HOST from cluster-settings ConfigMap in namespace ${namespace}"
    return 1
  fi

  if [[ -n "${image_push_port}" ]]; then
    image_push_endpoint="${image_push_endpoint}:${image_push_port}"
  fi

  echo "${image_push_endpoint}"
}

get_normalized_registry_url() {
  local registry_url="${1}"
  local registry_suffix="org.nguiland.infra"
  local normalized_url="${registry_url%/}"

  if [[ "${normalized_url}" != "${registry_suffix}" && "${normalized_url}" != */${registry_suffix} ]]; then
    normalized_url="${normalized_url}/${registry_suffix}"
  fi

  echo "${normalized_url}"
}

set_docker_build_pipeline_params() {
  local namespace="${1}"
  local manifest_path="${2}"

  if [[ -z "${namespace}" || -z "${manifest_path}" ]]; then
    log_error "Namespace and PipelineRun manifest path must be provided"
    return 1
  fi

  local image_push_endpoint
  image_push_endpoint=$(get_image_push_endpoint "${namespace}")

  if [[ -z "${image_push_endpoint}" ]]; then
    return 1
  fi

  set_pipeline_param "image-push-endpoint" "${image_push_endpoint}" "${manifest_path}"
  set_pipeline_param "always-build" "true" "${manifest_path}"

  local oci_res
  oci_res=$(get_artifactory_oci_resource "${namespace}")
  local skip_tls
  skip_tls=$(echo "${oci_res}" | jq -r 'if .spec.insecure == true then "true" else "false" end')

  set_pipeline_param "skip-tls" "${skip_tls}" "${manifest_path}"
}

set_oci_publish_pipeline_params() {
  local namespace="${1}"
  local manifest_path="${2}"

  if [[ -z "${namespace}" || -z "${manifest_path}" ]]; then
    log_error "Namespace and PipelineRun manifest path must be provided"
    return 1
  fi

  local oci_res
  oci_res=$(get_artifactory_oci_resource "${namespace}")
  local skip_tls
  skip_tls=$(echo "${oci_res}" | jq -r 'if .spec.insecure == true then "true" else "false" end')
  local registry_url
  registry_url=$(echo "${oci_res}" | jq -r '.spec.url // ""')

  set_pipeline_param "skip-tls" "${skip_tls}" "${manifest_path}"

  if [[ -n "${registry_url}" ]]; then
    local normalized_url
    normalized_url=$(get_normalized_registry_url "${registry_url}")
    set_pipeline_param "registry" "${normalized_url}" "${manifest_path}"
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
