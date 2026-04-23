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

  for mapping in "${port_forward_mappings[@]}"; do
    IFS=: read -r _ service_name namespace <<< "${mapping}"

    if [[ "${service_name}" == "${target_service_name}" && "${namespace}" == "${target_namespace}" ]]; then
      echo "${mapping}"
      return 0
    fi
  done

  return 1
}

start_port_forward_by_name() {
  local service_name="$1"
  local namespace="$2"

  local mapping
  mapping=$(get_port_forward_mapping "${service_name}" "${namespace}") || {
    printf "${YELLOW}WARN: No port forward mapping found for service '%s' in namespace '%s'. Skipping...${NO_COLOR}\n" "${service_name}" "${namespace}" >&2
    return 1
  }

  local host_port="${mapping%%:*}"
  start_single_port_forward "${host_port}" "${service_name}" "${namespace}"
}

start_single_port_forward() {
  local host_port="$1"
  local service_name="$2"
  local namespace="$3"
  
  local service_port

  if lsof -Pi :"$host_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    if [[ "${NGUILAND_FORCE_PORT_FORWARD:-false}" == "true" ]]; then
      printf "${YELLOW}WARN: Host port %s is in use. Terminating existing process...${NO_COLOR}\n" "${host_port}"
      lsof -ti :"$host_port" | xargs kill -9
    else
      printf "${YELLOW}WARN: Host port %s is already in use. Skipping...${NO_COLOR}\n" "${host_port}"
      return 0 # Indicate success for this service (skipped)
    fi
  fi

  if ! kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
    printf "${YELLOW}WARN: Service '%s' not found in namespace '%s'. Skipping...${NO_COLOR}\n" "${service_name}" "${namespace}"
    return 0 # Indicate success for this service (skipped)
  fi

  service_port=$(kubectl get svc "${service_name}" -n "${namespace}" -o jsonpath='{.spec.ports[0].port}')
  nohup kubectl port-forward --address="${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}" svc/"${service_name}" "${host_port}:${service_port}" -n "${namespace}" >/dev/null 2>&1 &

  # Wait a moment for the background process to initialize and bind to the port
  sleep 1
  if lsof -Pi :"$host_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    printf "${GREEN}INFO: Port forwarded, %s:%s -> svc/%s:%s (%s)${NO_COLOR}\n" "${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}" "${host_port}" "${service_name}" "${service_port}" "${namespace}"
  else
    printf "${YELLOW}WARN: Background process started but port %s is not listening. Forwarding might have failed.${NO_COLOR}\n" "${host_port}"
  fi
}

start_port_forwards() {
  for mapping in "${port_forward_mappings[@]}"; do
    IFS=: read -r host_port service_name namespace <<< "${mapping}"

    start_single_port_forward "${host_port}" "${service_name}" "${namespace}"
  done
}

# Direct-execution guard: only invoke start_port_forwards when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  start_port_forwards "$@"
fi
