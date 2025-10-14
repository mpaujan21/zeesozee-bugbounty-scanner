#!/usr/bin/env bash
# shellcheck shell=bash

set -o pipefail

HEADER="X-BugCrowd-Research: zeesozee"
HEADER2="X-HackerOne-Research: zeesozee"

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