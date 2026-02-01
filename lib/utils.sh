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