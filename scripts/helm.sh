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

suspend_helmreleases() {
  local namespace="${1}"
  shift

  # If no arguments are left, exit early
  [[ $# -eq 0 ]] && return 0

  local release_name
  for release_name in "$@"; do
    # Guard against empty strings/whitespace passed as arguments
    [[ -z "${release_name// /}" ]] && continue

    log_info "Suspending HelmRelease ${release_name} in namespace ${namespace}"
    wait_for_helmrelease_exists "${namespace}" "${release_name}" "10m"
    flux suspend hr "${release_name}" -n "${namespace}"
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
    flux resume hr "${release_name}" -n "${namespace}"
  done
}
