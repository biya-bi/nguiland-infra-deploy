#!/usr/bin/env bash

set -euo pipefail

YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NO_COLOR='\033[0m'

port_forward_mappings=(
  "9001:keycloak:infra"
  "9002:artifactory-jcr:infra"
  "9003:artifactory-oss:infra"
)

get_port_forward_mapping() {
  local target_service_name="$1"
  local target_namespace="$2"

  local mapping
  local _
  local service_name
  local namespace
  for mapping in "${port_forward_mappings[@]}"; do
    IFS=: read -r _ service_name namespace <<< "${mapping}"

    if [[ "${service_name}" == "${target_service_name}" && "${namespace}" == "${target_namespace}" ]]; then
      echo "${mapping}"
      return 0
    fi
  done

  return 1
}

get_host_name() {
  local host_address="$1"
  local host_name=""

  # 1. Python 3 (Most reliable on macOS and Linux)
  if command -v python3 >/dev/null 2>&1; then
    host_name=$(python3 -c "import socket; print(socket.gethostbyaddr('$host_address')[0])" 2>/dev/null || true)
  fi

  # 2. getent (Linux standard)
  if [[ -z "${host_name}" ]] && command -v getent >/dev/null 2>&1; then
    host_name=$(getent hosts "$host_address" 2>/dev/null | awk '{print $2}' | head -n 1 || true)
  fi

  # 3. dscacheutil (macOS standard)
  if [[ -z "${host_name}" ]] && command -v dscacheutil >/dev/null 2>&1; then
    host_name=$(dscacheutil -q host -a ip "$host_address" 2>/dev/null | grep 'name:' | awk '{print $2}' | head -n 1 || true)
  fi

  # Final Fallback: Return the name if found, otherwise the original IP
  echo "${host_name:-$host_address}"
}

start_port_forward_by_name() {
  local host_address="$1"
  local service_name="$2"
  local namespace="$3"

  local mapping
  mapping=$(get_port_forward_mapping "${service_name}" "${namespace}") || {
    printf "${YELLOW}WARN: No port forward mapping found for service '%s' in namespace '%s'. Skipping...${NO_COLOR}\n" "${service_name}" "${namespace}" >&2
    return 1
  }

  local host_port
  IFS=: read -r host_port service_name namespace <<< "${mapping}"

  start_single_port_forward "${host_address}" "${host_port}" "${service_name}" "${namespace}"
}

start_single_port_forward() {
  local host_address="$1"
  local host_port="$2"
  local service_name="$3"
  local namespace="${4:-default}"

  # Get hostname for more descriptive logging
  local host_name
  host_name=$(get_host_name "$host_address")

  # Construct display string to avoid "name (name)" redundancy
  local host_display="${host_name}"
  if [[ "${host_name}" != "${host_address}" ]]; then
    host_display="${host_name} (${host_address})"
  fi

  if lsof -Pi @"$host_address":"$host_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    # Verify if the tunnel is actually functional
    if ! nc -z -w 3 "$host_address" "$host_port" > /dev/null 2>&1; then
        printf "${YELLOW}Zombie port-forward detected on %s:%s. Cleaning up...${NO_COLOR}\n" "${host_display}" "${host_port}"
        lsof -ti @"$host_address":"$host_port" | xargs -r kill -9
        printf "${GREEN}Restarting port-forward on %s:%s...${NO_COLOR}\n" "${host_address}" "${host_port}"
    else
      printf "${YELLOW}WARN: Port %s on %s is active and healthy. Skipping...${NO_COLOR}\n" "${host_port}" "${host_display}"
      return 0
    fi
  else
    printf "${GREEN}INFO: Port %s on %s is free. Starting port-forward...${NO_COLOR}\n" "${host_port}" "${host_display}"
  fi

  if ! kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
    printf "${YELLOW}WARN: Service '%s' not found in namespace '%s'. Skipping...${NO_COLOR}\n" "${service_name}" "${namespace}"
    return 0
  fi

  local service_port
  service_port=$(kubectl get svc "${service_name}" -n "${namespace}" -o jsonpath='{.spec.ports[0].port}')

  nohup kubectl port-forward --address="$host_address" svc/"${service_name}" "${host_port}:${service_port}" -n "${namespace}" >/dev/null 2>&1 &

  # Wait a moment for the background process to initialize and bind to the port
  sleep 5
  if lsof -Pi @"$host_address":"$host_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    printf "${GREEN}INFO: Port forwarded, %s:%s -> svc/%s:%s (%s)${NO_COLOR}\n" "${host_display}" "${host_port}" "${service_name}" "${service_port}" "${namespace}"
  else
    printf "${YELLOW}WARN: Background process started but %s:%s is not listening. Forwarding might have failed.${NO_COLOR}\n" "${host_address}" "${host_port}"
  fi
}

start_port_forwards() {
  local host_address="$1"
  local mapping
  local host_port
  local service_name
  local namespace
  for mapping in "${port_forward_mappings[@]}"; do
    IFS=: read -r host_port service_name namespace <<< "${mapping}"

    start_single_port_forward "${host_address}" "${host_port}" "${service_name}" "${namespace}"
  done
}

# Direct-execution guard: only invoke start_port_forwards when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  start_port_forwards "$@"
fi
