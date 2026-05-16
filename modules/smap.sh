#!/usr/bin/env bash
# shellcheck shell=bash

smap_step() {
    local outdir="$1"

    if [[ ! -s "$outdir/clean_httpx.txt" ]]; then
        warn "No live hosts found; skipping Smap scan."
        return
    fi

    ok "Starting Smap passive port scan (Shodan data, no active probes)..."
    ensure_dir "$outdir/ports"

    # Extract unique hostnames/IPs from live hosts
    local targets_tmp
    targets_tmp=$(mktemp)
    sed -E 's|^https?://||; s|/.*$||; s|:.*$||' "$outdir/clean_httpx.txt" \
        | sort -u > "$targets_tmp"

    local target_count
    target_count=$(wc -l < "$targets_tmp")
    info "Querying Shodan for $target_count hosts (passive, no packets sent)..."

    local smap_grep="$outdir/ports/smap_greppable.txt"

    smap -iL "$targets_tmp" -oG "$smap_grep" 2>/dev/null || true
    rm -f "$targets_tmp"

    if [[ ! -s "$smap_grep" ]]; then
        info "No Shodan data returned for these hosts"
        return
    fi

    # Parse greppable output → host:port per line
    local open_ports_tmp
    open_ports_tmp=$(mktemp)
    grep "Ports:" "$smap_grep" | awk '{
        host = $2
        for (i = 1; i <= NF; i++) {
            if ($i ~ /\/open\//) {
                split($i, a, "/")
                gsub(/,/, "", a[1])
                print host ":" a[1]
            }
        }
    }' | sort -u > "$open_ports_tmp"

    local port_count
    port_count=$(wc -l "$open_ports_tmp" 2>/dev/null | awk '{print $1}'); port_count=${port_count:-0}

    if [[ $port_count -eq 0 ]]; then
        info "No open ports found in Shodan data"
        rm -f "$open_ports_tmp"
        return
    fi

    cp "$open_ports_tmp" "$outdir/ports/smap_open.txt"
    ok "Smap found $port_count open ports across $target_count hosts"

    # Probe HTTP services on discovered non-standard ports
    info "Probing discovered ports for HTTP services..."
    httpx -l "$open_ports_tmp" \
        -silent -nc \
        -title -tech-detect -status-code -web-server \
        -timeout 10 \
        -o "$outdir/ports/smap_http.txt" > /dev/null 2>&1

    rm -f "$open_ports_tmp"

    if [[ -s "$outdir/ports/smap_http.txt" ]]; then
        ok "Found $(wc -l < "$outdir/ports/smap_http.txt") HTTP services on non-standard ports"
    else
        info "No HTTP services found on discovered ports"
    fi

    ok "Smap scan completed"
}
