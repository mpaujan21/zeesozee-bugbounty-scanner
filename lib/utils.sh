#!/usr/bin/env bash
# shellcheck shell=bash

set -o pipefail

HEADER="X-HackerOne-Research: zeesozee"

ensure_dir() { mkdir -p "$1"; }

prompt_yn() {
  local q="$1" ans
  while true; do
    read -r -p "$(echo -e "${YELLOW}${q} (y/n): ${RESET}")" ans
    ans="${ans,,}"
    case "$ans" in y|yes) echo "y"; return;; n|no) echo "n"; return;; esac
    warn "Please answer with y or n."
  done
}

# run "desc" cmd...
run() {
  local desc="$1"; shift
  info "$desc"
  if ! "$@"; then
    warn "Command failed: $*"
    return 1
  fi
}

# Resume capability functions
STATE_FILE=""

init_state() {
  local outdir="$1"
  STATE_FILE="$outdir/.scan_state"
  [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
}

is_completed() {
  local step="$1"
  [[ -f "$STATE_FILE" ]] && grep -q "^${step}$" "$STATE_FILE"
}

mark_completed() {
  local step="$1"
  echo "$step" >> "$STATE_FILE"
  ok "Step '$step' completed"
}

clear_state() {
  [[ -f "$STATE_FILE" ]] && rm "$STATE_FILE"
  info "Cleared previous scan state"
}

resume_info() {
  if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
    local completed_count
    completed_count=$(wc -l < "$STATE_FILE")
    info "Found previous scan state with $completed_count completed steps"
    info "Resuming from last checkpoint..."
    return 0
  fi
  return 1
}

# Configuration loading functions
load_config() {
  local config_file="$1"

  if [[ ! -f "$config_file" ]]; then
    return 1
  fi

  info "Loading configuration from: $config_file"

  # Source the config file (only lines with KEY=VALUE format)
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] || [[ -z "$key" ]] && continue

    # Trim whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    # Export the variable
    export "$key=$value"
  done < "$config_file"

  ok "Configuration loaded"
  return 0
}

# Check if a tool is enabled in config (default: true)
is_tool_enabled() {
  local tool_var="$1"
  local enabled="${!tool_var}"

  # Default to true if not set
  if [[ -z "$enabled" ]]; then
    return 0
  fi

  # Check if enabled (case-insensitive)
  enabled="${enabled,,}" # lowercase
  [[ "$enabled" == "true" || "$enabled" == "1" || "$enabled" == "yes" || "$enabled" == "y" ]]
}

# Set default config values
set_default_config() {
  # Subdomain tools
  export ENABLE_SUBFINDER="${ENABLE_SUBFINDER:-true}"
  export ENABLE_ASSETFINDER="${ENABLE_ASSETFINDER:-true}"
  export ENABLE_FINDOMAIN="${ENABLE_FINDOMAIN:-true}"
  export ENABLE_AMASS="${ENABLE_AMASS:-true}"
  export ENABLE_CRTSH="${ENABLE_CRTSH:-true}"

  # Permutation tools
  export ENABLE_ALTERX="${ENABLE_ALTERX:-true}"
  export ENABLE_DNSGEN="${ENABLE_DNSGEN:-true}"
  export ENABLE_GOTATOR="${ENABLE_GOTATOR:-true}"

  # URL discovery tools
  export ENABLE_WAYBACKURLS="${ENABLE_WAYBACKURLS:-true}"
  export ENABLE_WAYMORE="${ENABLE_WAYMORE:-true}"
  export ENABLE_GAU="${ENABLE_GAU:-true}"
  export ENABLE_KATANA="${ENABLE_KATANA:-true}"
  export ENABLE_GOSPIDER="${ENABLE_GOSPIDER:-true}"

  # Performance settings
  export MAX_JS_FILES="${MAX_JS_FILES:-500}"
  export MAX_PARALLEL_JS="${MAX_PARALLEL_JS:-10}"
  export MAX_PARALLEL_BACKUPS="${MAX_PARALLEL_BACKUPS:-10}"
}