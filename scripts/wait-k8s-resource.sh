#!/usr/bin/env bash

set -euo pipefail

wait_resource_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${wait_resource_script_dir}/logger.sh"

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
  trap 'printf "\033[?25h"' RETURN
  log_info "${message} " false
  printf '\033[?25l'

  while true; do
    printf "%s" "${dot_states[dots]}"
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
        printf "\n"
        log_error "${resource_type}/${resource_name} entered a terminal failure state (CrashLoopBackOff/Error)."
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

    sleep 5
    printf "\b\b\b"
    dots=$(( (dots + 1) % 4 ))
  done
}

wait_for_deployment_available() {
  wait_for_resource "${1}" "deployment" "${2}" "condition=Available" "${3:-10m}"
}
