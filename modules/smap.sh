#!/usr/bin/env bash
# shellcheck shell=bash

smap_step() {
    local outdir="$1" threads="${2:-50}"

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

    # Active verification: rustscan top 1000 ports on smap-discovered hosts
    if command -v rustscan >/dev/null 2>&1; then
        if [[ -s "$outdir/ports/smap_open.txt" ]]; then
            info "Running rustscan (active, top 1000 ports) on smap-discovered hosts..."

            local rs_targets rs_raw
            rs_targets=$(mktemp)
            rs_raw=$(mktemp)

            cut -d: -f1 "$outdir/ports/smap_open.txt" | sort -u > "$rs_targets"
            local rs_host_count
            rs_host_count=$(wc -l < "$rs_targets")
            info "Rustscan targeting $rs_host_count hosts..."

            rustscan -a "$rs_targets" --top --no-banner -g --ulimit 5000 \
                2>/dev/null > "$rs_raw" || true

            rm -f "$rs_targets"

            if [[ -s "$rs_raw" ]]; then
                awk '{
                    host = $1
                    if (match($0, /\[([^]]+)\]/, arr)) {
                        n = split(arr[1], ports, ",")
                        for (i = 1; i <= n; i++) {
                            gsub(/[[:space:]]/, "", ports[i])
                            print host ":" ports[i]
                        }
                    }
                }' "$rs_raw" | sort -u > "$outdir/ports/rustscan_open.txt"

                local rs_count
                rs_count=$(wc -l "$outdir/ports/rustscan_open.txt" 2>/dev/null | awk '{print $1}'); rs_count=${rs_count:-0}
                ok "Rustscan found $rs_count open ports"

                if [[ $rs_count -gt 0 ]]; then
                    info "Probing rustscan ports for HTTP services..."
                    httpx -l "$outdir/ports/rustscan_open.txt" \
                        -silent -nc \
                        -title -tech-detect -status-code -web-server \
                        -timeout 10 \
                        -o "$outdir/ports/rustscan_http.txt" > /dev/null 2>&1

                    if [[ -s "$outdir/ports/rustscan_http.txt" ]]; then
                        ok "Found $(wc -l < "$outdir/ports/rustscan_http.txt") HTTP services via rustscan"
                    fi
                fi
            else
                info "Rustscan found no open ports"
            fi

            rm -f "$rs_raw"
        else
            info "No smap results to feed rustscan"
        fi
    else
        warn "rustscan not installed, skipping active port verification"
    fi

    # Service fingerprinting: identify non-HTTP services on all discovered open ports
    if command -v nerva >/dev/null 2>&1 && is_tool_enabled ENABLE_NERVA; then
        local nerva_targets
        nerva_targets=$(mktemp)
        cat "$outdir/ports/smap_open.txt" "$outdir/ports/rustscan_open.txt" 2>/dev/null \
            | sort -u > "$nerva_targets"

        if [[ -s "$nerva_targets" ]]; then
            local nerva_count
            nerva_count=$(wc -l < "$nerva_targets")
            info "Fingerprinting $nerva_count services with nerva (incl. misconfig checks)..."

            # NOTE: nerva --json writes JSONL (one `Service` object per line, not
            # a JSON array): {host,ip,port,protocol,version,metadata,security_findings}
            nerva -l "$nerva_targets" --misconfigs --json \
                -o "$outdir/ports/nerva.json" -W "$threads" \
                2>/dev/null || true

            if [[ -s "$outdir/ports/nerva.json" ]]; then
                jq -r '"\(.host // .ip):\(.port)\t\(.protocol)\t\(.version // "")"' \
                    "$outdir/ports/nerva.json" 2>/dev/null \
                    | sort -u > "$outdir/ports/nerva.txt" || true

                jq -r '
                    select(.security_findings != null and (.security_findings | length) > 0) as $svc
                    | $svc.security_findings[]
                    | "\($svc.host // $svc.ip):\($svc.port)\t\(.severity)\t\(.id)\t\(.description)"
                ' "$outdir/ports/nerva.json" 2>/dev/null \
                    | sort -u > "$outdir/ports/nerva_misconfigs.txt" || true
            fi

            if [[ -s "$outdir/ports/nerva.txt" ]]; then
                ok "Nerva fingerprinted $(wc -l < "$outdir/ports/nerva.txt") services"
            else
                info "Nerva returned no fingerprinted services"
            fi

            if [[ -s "$outdir/ports/nerva_misconfigs.txt" ]]; then
                ok "Nerva flagged $(wc -l < "$outdir/ports/nerva_misconfigs.txt") security misconfigurations"
            else
                info "Nerva found no security misconfigurations"
            fi
        else
            info "No open ports to fingerprint with nerva"
        fi

        rm -f "$nerva_targets"
    else
        warn "nerva not installed or disabled, skipping service fingerprinting"
    fi

    ok "Port scan completed (smap passive + rustscan active + nerva fingerprinting)"
}
