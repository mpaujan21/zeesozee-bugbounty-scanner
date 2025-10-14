#!/usr/bin/env bash
# shellcheck shell=bash

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"; BOLD="\e[1m"

banner() {
  echo -e "${BOLD}${BLUE}"
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║                 ZEESOZEE BUG BOUNTY SCANNER                   ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

info()    { echo -e "${BLUE}[*] $*${RESET}"; }
ok()      { echo -e "${GREEN}[+] $*${RESET}"; }
warn()    { echo -e "${YELLOW}[!] $*${RESET}"; }
err()     { echo -e "${RED}[!] $*${RESET}"; }
