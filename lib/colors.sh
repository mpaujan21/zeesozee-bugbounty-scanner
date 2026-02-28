#!/usr/bin/env bash
# shellcheck shell=bash

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"; BOLD="\e[1m"

# Structured logging to file
LOG_FILE=""

init_log() {
  LOG_FILE="$1/scan.log"
  echo "=== Zee Scanner Log ===" > "$LOG_FILE"
  echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
  echo "===" >> "$LOG_FILE"
}

_log() {
  [[ -n "$LOG_FILE" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE" || true
}

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║                 ZEESOZEE BUG BOUNTY SCANNER                   ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

info()    { echo -e "${BLUE}[*] $*${RESET}"; _log "INFO" "$*"; }
ok()      { echo -e "${GREEN}[+] $*${RESET}"; _log "OK" "$*"; }
warn()    { echo -e "${YELLOW}[!] $*${RESET}"; _log "WARN" "$*"; }
err()     { echo -e "${RED}[!] $*${RESET}"; _log "ERROR" "$*"; }
