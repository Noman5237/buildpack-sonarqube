#!/usr/bin/env bash

log() {
  echo "sonarqube-buildpack: $*"
}

fail() {
  echo "sonarqube-buildpack: ERROR: $*" >&2
  exit 1
}

is_true() {
  local value="${1:-false}"
  value="${value,,}"
  case "$value" in
    true|1|yes|on)     return 0 ;;
    false|0|no|off|"") return 1 ;;
    *)                 return 2 ;;
  esac
}

normalize_identifier() {
  local value="$1"
  printf '%s' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}
