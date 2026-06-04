#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"
. "${scripts_dir}/wait-k8s-resource.sh"

wait_for_gitrepository_exists() {
  wait_for_resource "${1}" "gitrepository" "${2}" "exists" "${3:-10m}"
}

wait_for_gitrepository() {
  wait_for_resource "${1}" "gitrepository" "${2}" "condition=Ready" "${3:-5m}"
}

wait_for_helmrepository_exists() {
  wait_for_resource "${1}" "helmrepository" "${2}" "exists" "${3:-10m}"
}

wait_for_helmrelease_exists() {
  wait_for_resource "${1}" "helmrelease" "${2}" "exists" "${3:-10m}"
}

wait_for_helmrelease() {
  wait_for_resource "${1}" "helmrelease" "${2}" "condition=Ready" "${3:-5m}"
}

reconcile_flux_resource() {
  local namespace="${1}"
  local resource_type="${2}"
  local resource_name="${3}"

  log_info "Triggering reconciliation signal for ${resource_type}/${resource_name} in namespace ${namespace}"
  kubectl patch "${resource_type}" "${resource_name}" -n "${namespace}" --type merge -p "{\"metadata\":{\"annotations\":{\"reconcile.toolkit.fluxcd.io/requestedAt\":\"$(date +%s)\"}}}" >/dev/null
}

toggle_resource_suspension() {
  local namespace="${1}"
  local resource_type="${2}"
  local resource_name="${3}"
  local suspend="${4}"

  kubectl patch "${resource_type}" "${resource_name}" -n "${namespace}" --type merge -p "{\"spec\":{\"suspend\":${suspend}}}" >/dev/null
}

reconcile_helm_release() {
  reconcile_flux_resource "${1}" "helmrelease" "${2}"
}

reconcile_git_repository() {
  reconcile_flux_resource "${1}" "gitrepository" "${2}"
}

ensure_git_repository_ready() {
  local namespace="${1}"
  local repo_name="${2}"
  local timeout="${3:-10m}"

  wait_for_gitrepository_exists "${namespace}" "${repo_name}" "${timeout}"
  reconcile_git_repository "${namespace}" "${repo_name}"
  wait_for_gitrepository "${namespace}" "${repo_name}" "${timeout}"
}

ensure_helm_release_ready() {
  local namespace="${1}"
  local release_name="${2}"
  local timeout="${3:-10m}"

  wait_for_helmrelease_exists "${namespace}" "${release_name}" "${timeout}"
  reconcile_helm_release "${namespace}" "${release_name}"
  wait_for_helmrelease "${namespace}" "${release_name}" "${timeout}"
}

suspend_helmreleases() {
  local namespace="${1}"
  shift

  # If no arguments are left, exit early
  [[ $# -eq 0 ]] && return 0

  local release_name
  for release_name in "$@"; do
    # Guard against empty strings/whitespace passed as arguments
    [[ -z "${release_name// /}" ]] && continue

    wait_for_helmrelease_exists "${namespace}" "${release_name}" "10m"
    log_info "Suspending HelmRelease ${release_name} in namespace ${namespace}"
    toggle_resource_suspension "${namespace}" "helmrelease" "${release_name}" "true"
  done
}

resume_helmreleases() {
  local namespace="${1}"
  shift

  # If no arguments are left, exit early
  [[ $# -eq 0 ]] && return 0

  local release_name
  for release_name in "$@"; do
    # Guard against empty strings/whitespace passed as arguments
    [[ -z "${release_name// /}" ]] && continue

    log_info "Resuming HelmRelease ${release_name} in namespace ${namespace}"
    toggle_resource_suspension "${namespace}" "helmrelease" "${release_name}" "false"
    reconcile_helm_release "${namespace}" "${release_name}"
  done
}

get_dependent_helmreleases() {
  local namespace="${1}"
  shift

  kubectl get helmrelease -n "${namespace}" -o json | jq -r --arg target_ns "${namespace}" '
    .items[] |
    select(
      .spec.dependsOn // [] |
      any(
        .name == $ARGS.positional[] and 
        ((.namespace == null) or (.namespace == $target_ns))
      )
    ) |
    .metadata.name
  ' --args "$@"
}
