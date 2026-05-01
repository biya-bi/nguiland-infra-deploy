#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Environment Variables (Optional Overrides)
# -----------------------------------------------------------------------------
# NGUILAND_ENABLE_PORT_FORWARD   : Explicitly enable or disable port-forwarding.
#                                  If unset, defaults based on the environment (enabled for local/int).
#                                  Values: 'true', 'false'.
#                                  Example: export NGUILAND_ENABLE_PORT_FORWARD="true"
# NGUILAND_PORT_FORWARD_ADDRESS  : The IP or hostname to bind the tunnels to.
#                                  Defaults to 'localhost'.
#                                  Example: export NGUILAND_PORT_FORWARD_ADDRESS="10.0.0.2"
#
# NGUILAND_PORT_FORWARD_LOG_FILE : The absolute or relative path for the log file.
#                                  Defaults to 'port-forward.log'.
#                                  Example: export NGUILAND_PORT_FORWARD_LOG_FILE="/var/log/pf.log"
# -----------------------------------------------------------------------------

set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"

port_forward_mappings=(
  "9001:keycloak:infra"
  "9002:artifactory-jcr:infra"
  "9003:artifactory-oss:infra"
)

enable_port_forward() {
  local environment="$1"

  local port_forward_enabled
  port_forward_enabled=$(echo "${NGUILAND_ENABLE_PORT_FORWARD:-}" | tr '[:upper:]' '[:lower:]' | xargs)

  if [[ "$port_forward_enabled" =~ ^true$ ]]; then
    # Port forwarding explicitly enabled
    return 0
  fi

  if [[ "$port_forward_enabled" =~ ^false$ ]]; then
    # Port forwarding explicitly disabled.
    return 1
  fi

  if [[ -n "$port_forward_enabled" ]]; then
    log_warn "The '$NGUILAND_ENABLE_PORT_FORWARD' value specified for NGUILAND_ENABLE_PORT_FORWARD is not valid."
    log_warn "Consider setting NGUILAND_ENABLE_PORT_FORWARD to 'true' or 'false' for explicit control."
    return 1
  fi

  # From here on, port_forward_enabled is blank (not set or empty).

  local env
  env=$(echo "${environment}" | tr '[:upper:]' '[:lower:]')

  if [[ "$env" =~ ^(local|int)$ ]]; then
    # Port forwarding enabled due to environment.
    log_warn "NGUILAND_ENABLE_PORT_FORWARD is not explicitly set. Port forwarding is enabled for environment '$environment'."
    return 0
  else
    log_debug "NGUILAND_ENABLE_PORT_FORWARD is not explicitly set. Port forwarding is disabled for environment '$environment'."
    log_debug "Consider setting NGUILAND_ENABLE_PORT_FORWARD to 'true' or 'false' for explicit control."
    return 1
  fi
}

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
    log_warn "No port forward mapping found for service '${service_name}' in namespace '${namespace}'. Skipping..." >&2
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
    # Check if the HTTP service is actually responding
    # We use -L to follow redirects and --max-time to keep it snappy
    if ! curl -sL --max-time 3 "http://${host_address}:${host_port}" > /dev/null; then
        log_warn "Port ${host_port} is listening on ${host_display} but service is unresponsive (Tunnel Timeout). Cleaning up..."
        local pids
        pids=$(lsof -tni @"$host_address":"$host_port" -sTCP:LISTEN || true)
        [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null || true
        log_info "Restarting port-forward on ${host_address}:${host_port}..."
    else
      log_info "Port ${host_port} on ${host_display} is active and healthy."
      return 0
    fi
  else
    log_info "Port ${host_port} on ${host_display} is free. Starting port-forward..."
  fi

  if ! kubectl get svc "${service_name}" -n "${namespace}" >/dev/null 2>&1; then
    log_warn "Service '${service_name}' not found in namespace '${namespace}'. Skipping..."
    return 0
  fi

  local service_port
  service_port=$(kubectl get svc "${service_name}" -n "${namespace}" -o jsonpath='{.spec.ports[0].port}')

  nohup kubectl port-forward --address="$host_address" svc/"${service_name}" "${host_port}:${service_port}" -n "${namespace}" >/dev/null 2>&1 &

  # Wait a moment for the background process to initialize and bind to the port
  sleep 5
  if lsof -Pi @"$host_address":"$host_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    log_info "Port forwarded, ${host_display}:${host_port} -> svc/${service_name}:${service_port} (${namespace})"
  else
    log_warn "Background process started but ${host_address}:${host_port} is not listening. Forwarding might have failed."
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

watch_port_forwards() {
  local host_address="$1"
  local log_file="$2"

  # Initialize the timer
  local last_rotation=$(date +%s)
  local current_time

  while true; do
    current_time=$(date +%s)

    # 1. DELETE .old files more than 2 hours (7200 seconds) old
    find "$(dirname "$log_file")" -name "$(basename "$log_file").old" -mmin +120 -delete 2>/dev/null || true

    # 2. ROTATE every 1 hour (3600 seconds) regardless of recent writes
    if (( current_time - last_rotation >= 3600 )); then
      if [[ -s "${log_file}" ]]; then
        log_info "1 hour elapsed since last rotation. Rotating..."

        rotate_log_file "${log_file}"

        # Reset the timer
        last_rotation=$current_time
      fi
    fi

    start_port_forwards "$host_address"
    sleep 10
  done
}

# Direct-execution guard: only invoke start_port_forwards when this script is executed directly,
# not when it is sourced into another shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # 1. Kill previous background processes
  previous_pids=$(pgrep -f "$(basename "$0")" | grep -v "^$$" || echo "")

  if [[ -n "$previous_pids" ]]; then
    log_warn "Found existing watchdog process(es): ${previous_pids}. Terminating..."
    kill -9 $previous_pids 2>/dev/null || true
    sleep 1
  fi

  log_file="${NGUILAND_PORT_FORWARD_LOG_FILE:-port-forward.log}"

  # 2. Log Rotation: Keep only one previous version
  if [[ -f "$log_file" && -s "$log_file" ]]; then
    rotated_log_file=$(rotate_log_file "${log_file}")
    log_info "Rotated previous log file to ${rotated_log_file}"
  fi

  # 3. Check if a 'nohup' flag was passed
  if [[ "${1:-}" != "--no-detach" ]]; then
    log_info "Detaching and running in background..."
    nohup "$0" --no-detach >> "$log_file" 2>&1 &
    exit 0
  fi

  host_address="${NGUILAND_PORT_FORWARD_ADDRESS:-localhost}"

  watch_port_forwards "$host_address" "$log_file"
fi
