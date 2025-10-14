#!/usr/bin/env bash
# shellcheck shell=bash

nuclei_step() {
  local outdir="$1"
  [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live targets for nuclei."; return; }
  command -v nuclei >/dev/null || { warn "nuclei not installed."; return; }

  ok "Running Nuclei vulnerability scanner..."
  ensure_dir "$outdir/nuclei"
  info "Updating Nuclei templates..."
  nuclei -update-templates

  info "Scanning for critical/high..."
  cat "$outdir/clean_httpx.txt" | nuclei -silent -severity critical,high -o "$outdir/nuclei/critical_high.txt" -H "$HEADER" -H "$HEADER2"

  info "Scanning for medium..."
  cat "$outdir/clean_httpx.txt" | nuclei -silent -severity medium -o "$outdir/nuclei/medium.txt" -H "$HEADER" -H "$HEADER2"

  ok "Nuclei scanning completed"
}
