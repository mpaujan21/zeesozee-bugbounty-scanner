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

    # Validate httpx.json exists and is valid
    if ! validate_json "$outdir/httpx.json" "httpx results"; then
        warn "httpx.json not found or invalid; skipping port scan"
        return
    fi

    ok "Starting port scanning..."
    ensure_dir "$outdir/ports"

    # Extract IPs from JSON (exclude CDN IPs)
    if ! jq -r 'select(.cdn == null or .cdn == false) | .host // .a // empty' "$outdir/httpx.json" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u > "$outdir/ips.txt" 2>/dev/null; then
        warn "Failed to extract IPs from httpx.json"
    fi

    # Also extract hostnames for non-IP targets
    if ! jq -r 'select(.cdn == null or .cdn == false) | .input // empty' "$outdir/httpx.json" \
        | sort -u > "$outdir/hosts_for_portscan.txt" 2>/dev/null; then
        warn "Failed to extract hostnames from httpx.json"
    fi

    if [[ ! -s "$outdir/ips.txt" ]]; then
        warn "No IPs extracted, trying hostnames..."
        cp "$outdir/hosts_for_portscan.txt" "$outdir/ips.txt"
    fi

    if [[ ! -s "$outdir/ips.txt" ]]; then
        warn "No targets for port scan."
        return
    fi

    local target_count
    target_count=$(wc -l < "$outdir/ips.txt")
    info "Scanning $target_count targets (CDN IPs excluded)"

    # Port scan with naabu
    naabu -l "$outdir/ips.txt" \
        -p "$ALL_PORTS" \
        -rate "$threads" \
        -c "$threads" \
        -timeout 5000 \
        -retries 2 \
        -silent \
        -o "$outdir/ports/naabu_output.txt"

    if [[ -s "$outdir/ports/naabu_output.txt" ]]; then
        local open_count
        open_count=$(wc -l < "$outdir/ports/naabu_output.txt")
        ok "Found $open_count open ports"

        # Probe discovered ports with httpx (JSON output)
        info "Probing open ports for HTTP services..."
        httpx -l "$outdir/ports/naabu_output.txt" \
            -silent -nc \
            -title -tech-detect -status-code -web-server \
            -timeout 10 \
            -threads "$threads" \
            -json -o "$outdir/ports/httpx_ports.json"

        # Validate httpx_ports.json before processing
        if validate_json "$outdir/ports/httpx_ports.json" "httpx ports results"; then
            # Generate human-readable format from JSON
            if jq -r '[.url, "[\(.status_code)]", "[\(.title // "")]", "[\(.webserver // "")]", "[\(.tech // [] | join(","))]"] | join(" ")' \
                "$outdir/ports/httpx_ports.json" > "$outdir/ports/httpx_ports.txt" 2>/dev/null; then
                if [[ -s "$outdir/ports/httpx_ports.txt" ]]; then
                    ok "Found $(wc -l < "$outdir/ports/httpx_ports.txt") HTTP services on non-standard ports"
                fi
            else
                warn "Failed to parse httpx ports results"
            fi
        else
            warn "httpx did not produce valid JSON for port probing"
        fi
    else
        info "No additional open ports found"
    fi

    ok "Port scanning completed"
}
