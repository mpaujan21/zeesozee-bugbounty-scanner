#!/usr/bin/env bash
# shellcheck shell=bash

# Ports organized by category/common vulnerabilities
# Web servers
PORTS_WEB="80,81,443,8080,8081,8443,8000,8001,8008,8888,9000,9001,9080,9443"

# Dev/Framework servers (often exposed accidentally)
PORTS_DEV="3000,3001,4000,4200,4443,5000,5001,5173,8000,8001"

# Admin panels & management interfaces
PORTS_ADMIN="9090,10000,8834,8181,8444"

# Application servers (known CVEs)
PORTS_APPSERVER="8009,8180,8880,7001,7002,4848,8983,8161,61616"

# APIs & services (often misconfigured)
PORTS_API="6443,9200,9300,5601,15672,2375,2376"

# Databases (often exposed without auth)
PORTS_DB="27017,6379,5432,3306,1433,11211,9042"

# CI/CD & DevOps
PORTS_CICD="8082,9418,50000,50001,2049,873"

# Combine all ports
ALL_PORTS="${PORTS_WEB},${PORTS_DEV},${PORTS_ADMIN},${PORTS_APPSERVER},${PORTS_API},${PORTS_DB},${PORTS_CICD}"

ports_step() {
    local outdir="$1" threads="${2:-50}"

    if [[ ! -s "$outdir/httpx_pretty.json" ]]; then
        warn "httpx_pretty.json not found; skipping port scan"
        return
    fi

    ok "Starting port scanning..."
    ensure_dir "$outdir/ports"

    local targets_tmp
    targets_tmp=$(mktemp)

    # Extract IPs from JSON (exclude CDN IPs)
    jq -r '.[] | select(.cdn == null or .cdn == false) | .host // .a // empty' "$outdir/httpx_pretty.json" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u > "$targets_tmp" 2>/dev/null

    # Fallback to hostnames if no IPs found
    if [[ ! -s "$targets_tmp" ]]; then
        warn "No IPs extracted, trying hostnames..."
        jq -r '.[] | select(.cdn == null or .cdn == false) | .input // empty' "$outdir/httpx_pretty.json" \
            | sort -u > "$targets_tmp" 2>/dev/null
    fi

    if [[ ! -s "$targets_tmp" ]]; then
        warn "No targets for port scan."
        rm -f "$targets_tmp"
        return
    fi

    local target_count
    target_count=$(wc -l < "$targets_tmp")
    info "Scanning $target_count targets (CDN IPs excluded)"

    local open_ports_tmp
    open_ports_tmp=$(mktemp)

    # Port scan with rustscan, convert greppable output to host:port per line
    rustscan -a "$targets_tmp" \
        -p "$ALL_PORTS" \
        -b "$threads" \
        -t 5000 \
        --tries 2 \
        --scripts none \
        -g 2>/dev/null \
    | awk -F' -> ' '{
        gsub(/[\[\]]/, "", $2)
        split($2, ports, ",")
        for (i in ports) print $1 ":" ports[i]
    }' > "$open_ports_tmp"
    rm -f "$targets_tmp"

    if [[ -s "$open_ports_tmp" ]]; then
        local open_count
        open_count=$(wc -l < "$open_ports_tmp")
        ok "Found $open_count open ports"

        # Probe discovered ports with httpx
        info "Probing open ports for HTTP services..."
        httpx -l "$open_ports_tmp" \
            -silent -nc \
            -title -tech-detect -status-code -web-server \
            -timeout 10 \
            -threads "$threads" \
            -o "$outdir/ports/httpx_ports.txt" > /dev/null 2>&1

        if [[ -s "$outdir/ports/httpx_ports.txt" ]]; then
            ok "Found $(wc -l < "$outdir/ports/httpx_ports.txt") HTTP services on non-standard ports"
        fi
    else
        info "No additional open ports found"
    fi
    rm -f "$open_ports_tmp"

    ok "Port scanning completed"
}
