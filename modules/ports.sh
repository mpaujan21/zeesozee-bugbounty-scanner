#!/usr/bin/env bash
# shellcheck shell=bash

ports_step() {
    local outdir="$1" threads="${2:-50}"
    [[ -s "$outdir/httpx.txt" ]] || { warn "No httpx.txt; skipping port scan."; return; }
    ok "Starting port scanning..."
    ensure_dir "$outdir/ports"
    awk '{print $3}' "$outdir/httpx.txt" | sed 's/\[//g;s/\]//g' | sort -u > "$outdir/ips.txt"
    if [[ ! -s "$outdir/ips.txt" ]]; then warn "No IPs extracted."; return; fi
    
    run "Scanning common web ports with naabu" naabu -iL "$outdir/ips.txt" -p 80,81,443,3000,3001,4443,5000,5001,8000,8001,8008,8080,8081,8443,8888,9000,9001,9080,9443,10000 -silent -o "$outdir/ports/naabu_output.txt"
    if [[ -s "$outdir/ports/naabu_output.txt" ]]; then
        run "Enumerating services on open ports" bash -c "cat '$outdir/ports/naabu_output.txt' | httpx -silent -title -tech-detect -status-code -o '$outdir/ports/httpx_ports.txt'"
    fi
    ok "Port scanning completed"
}
