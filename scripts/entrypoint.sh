#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "${script_dir}/yq.sh"
. "${script_dir}/helm.sh"
. "${script_dir}/wait-k8s-resource.sh"
. "${script_dir}/pipelines.sh"
. "${script_dir}/port-forward.sh"

cleanup_terminal() {
  printf '\033[?25h'
}
trap cleanup_terminal EXIT
trap 'exit 130' INT

main() {
  local namespace="infra"

  local port_forward_address="${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}"

  local jcr_service_name="artifactory-jcr"
  local oss_service_name="artifactory-oss"

  local addons=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    addons+=("$line")
  done < <(get_dependent_helmreleases "${namespace}" "${jcr_service_name}" "${oss_service_name}")

  suspend_helmreleases "${namespace}" "${addons[@]:-}"

  # Ensure we resume even if the middle steps fail
  trap "resume_helmreleases ${namespace} ${addons[*]:-} || true; cleanup_terminal" EXIT

  wait_for_deployment_available "${namespace}" "${jcr_service_name}" "15m"

  local docker_build_manifest_path="infra/docker/build.yaml"
  local oci_publish_manifest_path="infra/oci/publish.yaml"

  local pipeline_manifest_paths=()
  pipeline_manifest_paths+=("${docker_build_manifest_path}")
  pipeline_manifest_paths+=("${oci_publish_manifest_path}")

  local pipeline_name
  local relative_path
  for relative_path in "${pipeline_manifest_paths[@]}"; do
    pipeline_name=$(get_pipeline_name "$relative_path")
    wait_for_pipeline_exists "${namespace}" "${pipeline_name}" "15m"
  done

  # Before running the docker-publish pipeline, we need to start a port-forward
  # for artifactory-jcr so that the pipeline does not fail. This is particularly
  # important on environments (such as int) with Wireguard
  start_port_forward_by_name "${port_forward_address}" "${jcr_service_name}" "${namespace}"

  run_docker_build_pipeline "${namespace}" "${docker_build_manifest_path}"
  run_oci_publish_pipeline "${namespace}" "${oci_publish_manifest_path}"
  wait_for_helmrepository_exists "${namespace}" "artifactory-oci" "10m"

  # Explicitly resume and clear the trap if we finish normally
  resume_helmreleases "${namespace}" "${addons[@]:-}"

  "${script_dir}/port-forward.sh"

  trap - EXIT
}

# Direct-execution guard: only invoke main when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
