#!/usr/bin/env bash

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"
. "${scripts_dir}/helm.sh"

reconcile_helm_release() {
  local namespace="${1}"
  local release_name="${2}"
  local with_source="${3:-false}"

  local args=()
  local info_suffix=""
  if [[ "${with_source}" == "true" ]]; then
    args+=("--with-source")
    info_suffix=" (with source)"
  fi

  log_info "Triggering reconciliation of HelmRelease ${release_name}${info_suffix} in namespace ${namespace}"
  flux reconcile hr "${release_name}" "${args[@]}" -n "${namespace}"
}

reconcile_git_repository() {
  local namespace="${1}"
  local repo_name="${2}"

  log_info "Triggering reconciliation of GitRepository ${repo_name} in namespace ${namespace}"
  flux reconcile source git "${repo_name}" -n "${namespace}"
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
  local with_source="${4:-false}"

  wait_for_helmrelease_exists "${namespace}" "${release_name}" "${timeout}"
  reconcile_helm_release "${namespace}" "${release_name}" "${with_source}"
  wait_for_helmrelease "${namespace}" "${release_name}" "${timeout}"
}
