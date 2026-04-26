#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NO_COLOR='\033[0m'

log() {
  local level_color="$1"
  local level_name="$2"
  local message="$3"
  local add_newline="${4:-true}"
  local timestamp
  timestamp=$(date +'%Y-%m-%dT%H:%M:%S')

  local nl=""
  [[ "${add_newline}" == "true" ]] && nl="\n"
  printf "${timestamp} ${level_color}${level_name}${NO_COLOR} ${message}${nl}"
}

log_info() {
  log "${GREEN}" "INFO" "$1" "${2:-true}"
}

log_warn() {
  log "${YELLOW}" "WARN" "$1" "${2:-true}" >&2
}

log_error() {
  log "${RED}" "ERROR" "$1" "${2:-true}" >&2
}
