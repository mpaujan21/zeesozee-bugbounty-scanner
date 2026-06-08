#!/usr/bin/env bash
# shellcheck shell=bash

# Helper to count lines in file
count_lines() {
    [[ -f "$1" ]] && wc -l < "$1" 2>/dev/null || echo 0
}

# Helper to check if file has content
has_content() {
    [[ -s "$1" ]]
}

report_step() {
    local outdir="$1" domain="$2" start_time="${3:-}"
    local report_json="$outdir/report.json"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    ok "Generating summary report..."

    # Calculate duration if start time provided
    local duration=""
    if [[ -n "$start_time" ]]; then
        local end_time
        end_time=$(date +%s)
        local diff=$((end_time - start_time))
        duration="$(($diff / 3600))h $((($diff % 3600) / 60))m $(($diff % 60))s"
    fi

    # Gather all stats
    local subdomains_total subdomains_live urls_total urls_optimized
    local js_files ports_open nerva_services nerva_misconfigs
    local secrets_found titus_secrets endpoints_found permutation_new

    local takeover_count screenshots_count
    takeover_count=$(grep -c '^\[VULNERABLE\]' "$outdir/takeover/potential_takeovers.txt" 2>/dev/null) || takeover_count=0
    screenshots_count=$(find "$outdir/screenshots" -name "*.png" 2>/dev/null | wc -l) || screenshots_count=0

    subdomains_total=$(count_lines "$outdir/subdomains.txt")
    subdomains_live=$(count_lines "$outdir/clean_httpx.txt")
    urls_total=$(count_lines "$outdir/urls.txt")
    urls_optimized=$(count_lines "$outdir/urls_optimized.txt")
    js_files=$(count_lines "$outdir/js.txt")
    ports_open=$(cat "$outdir/ports/smap_open.txt" "$outdir/ports/rustscan_open.txt" 2>/dev/null | sort -u | wc -l)
    nerva_services=$(count_lines "$outdir/ports/nerva.txt")
    nerva_misconfigs=$(count_lines "$outdir/ports/nerva_misconfigs.txt")
    secrets_found=$(count_lines "$outdir/js/analysis/trufflehog.txt")
    titus_secrets=$(count_lines "$outdir/js/analysis/titus.txt")
    endpoints_found=$(count_lines "$outdir/js/analysis/all_endpoints.txt")
    permutation_new=$(count_lines "$outdir/permutations/live.txt")
    jshunter_jwt=$(count_lines "$outdir/js/analysis/jshunter_jwt.txt")
    jshunter_firebase=$(count_lines "$outdir/js/analysis/jshunter_firebase.txt")
    jshunter_graphql=$(count_lines "$outdir/js/analysis/jshunter_graphql.txt")
    jshunter_params=$(count_lines "$outdir/js/analysis/jshunter_params.txt")

    # Generate JSON Report
    cat > "$report_json" << EOF
{
  "scan_info": {
    "target": "$domain",
    "timestamp": "$timestamp",
    "duration": "${duration:-null}",
    "output_dir": "$outdir"
  },
  "summary": {
    "subdomains_total": $subdomains_total,
    "subdomains_live": $subdomains_live,
    "permutation_new": $permutation_new,
    "ports_open": $ports_open,
    "nerva_services": $nerva_services,
    "nerva_misconfigs": $nerva_misconfigs,
    "urls_total": $urls_total,
    "urls_optimized": $urls_optimized,
    "js_files": $js_files,
    "endpoints_found": $endpoints_found,
    "secrets_found": $secrets_found,
    "titus_secrets": $titus_secrets,
    "jwt_tokens": $jshunter_jwt,
    "firebase_configs": $jshunter_firebase,
    "graphql_endpoints": $jshunter_graphql,
    "hidden_params": $jshunter_params,
    "takeover_count": $takeover_count,
    "screenshots_count": $screenshots_count
  },
  "high_priority": {
    "has_secrets": $([ "$secrets_found" -gt 0 ] && echo "true" || echo "false"),
    "has_titus_secrets": $([ "$titus_secrets" -gt 0 ] && echo "true" || echo "false"),
    "has_firebase": $([ "$jshunter_firebase" -gt 0 ] && echo "true" || echo "false"),
    "has_jwt": $([ "$jshunter_jwt" -gt 0 ] && echo "true" || echo "false"),
    "has_takeovers": $([ "$takeover_count" -gt 0 ] && echo "true" || echo "false"),
    "has_misconfigs": $([ "$nerva_misconfigs" -gt 0 ] && echo "true" || echo "false")
  }
}
EOF

    ok "JSON report saved to: $report_json"

    # Print summary to stdout
    echo
    echo "════════════════════════════════════════════════════════════"
    echo "  SCAN COMPLETE: $domain"
    echo "════════════════════════════════════════════════════════════"
    echo "  Subdomains: $subdomains_live live / $subdomains_total total"
    echo "  URLs: $urls_optimized optimized / $urls_total total"
    echo "  Open ports: $ports_open"
    echo "  Fingerprinted services: $nerva_services"
    echo "  JS Files: $js_files"
    echo "  Endpoints: $endpoints_found"
    [[ $takeover_count -gt 0 ]] && echo "  ⚠ TAKEOVERS FOUND: $takeover_count"
    [[ $nerva_misconfigs -gt 0 ]] && echo "  ⚠ MISCONFIGS FOUND: $nerva_misconfigs"
    [[ $secrets_found -gt 0 ]] && echo "  ⚠ SECRETS FOUND: $secrets_found"
    [[ $titus_secrets -gt 0 ]] && echo "  ⚠ TITUS SECRETS FOUND: $titus_secrets"
    [[ $screenshots_count -gt 0 ]] && echo "  Screenshots: $screenshots_count"
    echo "════════════════════════════════════════════════════════════"
    echo "  Report: $report_json"
    echo "════════════════════════════════════════════════════════════"
    echo
}
