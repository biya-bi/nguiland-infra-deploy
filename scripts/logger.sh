#!/usr/bin/env bash

set -euo pipefail

log() {
  local level_color="$1"
  local level_name="$2"
  local message="$3"
  local timestamp
  timestamp=$(date +'%Y-%m-%dT%H:%M:%S')

  printf "${timestamp} ${level_color}${level_name}${NO_COLOR} ${message}\n"
}
