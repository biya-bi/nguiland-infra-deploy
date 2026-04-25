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
  local timestamp
  timestamp=$(date +'%Y-%m-%dT%H:%M:%S')

  printf "${timestamp} ${level_color}${level_name}${NO_COLOR} ${message}\n"
}

log_info() {
  log "${GREEN}" "INFO" "$1"
}

log_warn() {
  log "${YELLOW}" "WARN" "$1"
}

log_error() {
  log "${RED}" "ERROR" "$1"
}
