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
    local report_md="$outdir/report.md"
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
    local js_files ports_open
    local secrets_found endpoints_found permutation_new

    subdomains_total=$(count_lines "$outdir/subdomains.txt")
    subdomains_live=$(count_lines "$outdir/clean_httpx.txt")
    urls_total=$(count_lines "$outdir/urls.txt")
    urls_optimized=$(count_lines "$outdir/uro.txt")
    js_files=$(count_lines "$outdir/js.txt")
    ports_open=$(count_lines "$outdir/ports/naabu_output.txt")
    secrets_found=$(count_lines "$outdir/js/analysis/trufflehog.txt")
    endpoints_found=$(count_lines "$outdir/js/analysis/all_endpoints.txt")
    permutation_new=$(count_lines "$outdir/permutations/live.txt")

    # Per-tool effectiveness metrics
    local tool_subfinder tool_assetfinder tool_findomain tool_amass tool_crtsh
    local tool_waybackurls tool_waymore tool_gau tool_katana tool_gospider
    local tool_jsluice tool_linkfinder

    tool_subfinder=$(count_lines "$outdir/subdomains/subfinder.txt")
    tool_assetfinder=$(count_lines "$outdir/subdomains/assetfinder.txt")
    tool_findomain=$(count_lines "$outdir/subdomains/findomain.txt")
    tool_amass=$(count_lines "$outdir/subdomains/amass.txt")
    tool_crtsh=$(count_lines "$outdir/subdomains/crtsh.txt")
    tool_waybackurls=$(count_lines "$outdir/urls/waybackurls.txt")
    tool_waymore=$(count_lines "$outdir/urls/waymore.txt")
    tool_gau=$(count_lines "$outdir/urls/gau.txt")
    tool_katana=$(count_lines "$outdir/urls/katana.txt")
    tool_gospider=$(count_lines "$outdir/urls/gospider.txt")
    tool_jsluice=$(count_lines "$outdir/js/analysis/jsluice_urls.txt")
    tool_linkfinder=$(count_lines "$outdir/js/analysis/linkfinder.txt")

    # Generate Markdown Report
    cat > "$report_md" << EOF
# Bug Bounty Scan Report

## Scan Information
| Field | Value |
|-------|-------|
| **Target** | $domain |
| **Date** | $timestamp |
| **Duration** | ${duration:-N/A} |
| **Output Directory** | $outdir |

---

## Summary

| Category | Count |
|----------|-------|
| Subdomains Found | $subdomains_total |
| Live Subdomains | $subdomains_live |
| New from Permutations | $permutation_new |
| Open Ports | $ports_open |
| URLs Discovered | $urls_total |
| URLs (optimized) | $urls_optimized |
| JavaScript Files | $js_files |
| JS Endpoints | $endpoints_found |
| Secrets Found | $secrets_found |

---

## High Priority Findings

EOF

    # Secrets section
    if [[ $secrets_found -gt 0 ]]; then
        echo "### Secrets Found (CRITICAL)" >> "$report_md"
        echo '```' >> "$report_md"
        head -20 "$outdir/js/analysis/trufflehog.txt" >> "$report_md" 2>/dev/null
        [[ $secrets_found -gt 20 ]] && echo "... and $((secrets_found - 20)) more" >> "$report_md"
        echo '```' >> "$report_md"
        echo >> "$report_md"
    fi

    # Source maps warning
    if has_content "$outdir/js/analysis/sourcemaps.txt"; then
        local map_count
        map_count=$(count_lines "$outdir/js/analysis/sourcemaps.txt")
        echo "### Source Maps Found (may expose source code)" >> "$report_md"
        echo '```' >> "$report_md"
        head -10 "$outdir/js/analysis/sourcemaps.txt" >> "$report_md" 2>/dev/null
        [[ $map_count -gt 10 ]] && echo "... and $((map_count - 10)) more" >> "$report_md"
        echo '```' >> "$report_md"
        echo >> "$report_md"
    fi

    # GF Pattern Results
    echo "---" >> "$report_md"
    echo >> "$report_md"
    echo "## GF Pattern Results" >> "$report_md"
    echo >> "$report_md"
    echo "| Pattern | Count |" >> "$report_md"
    echo "|---------|-------|" >> "$report_md"

    for pattern in sqli xss ssrf redirect rce lfi idor ssti params debug upload cors aws php_errors; do
        local pattern_file="$outdir/categorized/${pattern}.txt"
        if has_content "$pattern_file"; then
            local count
            count=$(count_lines "$pattern_file")
            echo "| $pattern | $count |" >> "$report_md"
        fi
    done

    # Tool effectiveness metrics
    echo >> "$report_md"
    echo "---" >> "$report_md"
    echo >> "$report_md"
    echo "## Tool Effectiveness" >> "$report_md"
    echo >> "$report_md"
    echo "### Subdomain Enumeration" >> "$report_md"
    echo "| Tool | Results |" >> "$report_md"
    echo "|------|---------|" >> "$report_md"
    [[ $tool_subfinder -gt 0 ]] && echo "| subfinder | $tool_subfinder |" >> "$report_md"
    [[ $tool_assetfinder -gt 0 ]] && echo "| assetfinder | $tool_assetfinder |" >> "$report_md"
    [[ $tool_findomain -gt 0 ]] && echo "| findomain | $tool_findomain |" >> "$report_md"
    [[ $tool_amass -gt 0 ]] && echo "| amass | $tool_amass |" >> "$report_md"
    [[ $tool_crtsh -gt 0 ]] && echo "| crt.sh | $tool_crtsh |" >> "$report_md"
    echo "| **Combined (deduped)** | **$subdomains_total** |" >> "$report_md"
    echo >> "$report_md"
    echo "### URL Discovery" >> "$report_md"
    echo "| Tool | Results |" >> "$report_md"
    echo "|------|---------|" >> "$report_md"
    [[ $tool_waybackurls -gt 0 ]] && echo "| waybackurls | $tool_waybackurls |" >> "$report_md"
    [[ $tool_waymore -gt 0 ]] && echo "| waymore | $tool_waymore |" >> "$report_md"
    [[ $tool_gau -gt 0 ]] && echo "| gau | $tool_gau |" >> "$report_md"
    [[ $tool_katana -gt 0 ]] && echo "| katana | $tool_katana |" >> "$report_md"
    [[ $tool_gospider -gt 0 ]] && echo "| gospider | $tool_gospider |" >> "$report_md"
    echo "| **Combined (deduped)** | **$urls_total** |" >> "$report_md"
    echo >> "$report_md"

    if [[ $tool_jsluice -gt 0 || $tool_linkfinder -gt 0 ]]; then
        echo "### JS Analysis" >> "$report_md"
        echo "| Tool | Results |" >> "$report_md"
        echo "|------|---------|" >> "$report_md"
        [[ $tool_jsluice -gt 0 ]] && echo "| jsluice | $tool_jsluice |" >> "$report_md"
        [[ $tool_linkfinder -gt 0 ]] && echo "| LinkFinder | $tool_linkfinder |" >> "$report_md"
        echo "| **Combined (deduped)** | **$endpoints_found** |" >> "$report_md"
        echo >> "$report_md"
    fi

    # Port scan results
    if has_content "$outdir/ports/httpx_ports.txt"; then
        echo >> "$report_md"
        echo "---" >> "$report_md"
        echo >> "$report_md"
        echo "## Open Ports with HTTP Services" >> "$report_md"
        echo '```' >> "$report_md"
        head -20 "$outdir/ports/httpx_ports.txt" >> "$report_md" 2>/dev/null
        [[ $ports_open -gt 20 ]] && echo "... and more" >> "$report_md"
        echo '```' >> "$report_md"
    fi

    # JS Endpoints
    if has_content "$outdir/js/analysis/all_endpoints.txt"; then
        echo >> "$report_md"
        echo "---" >> "$report_md"
        echo >> "$report_md"
        echo "## JavaScript Endpoints (sample)" >> "$report_md"
        echo '```' >> "$report_md"
        head -30 "$outdir/js/analysis/all_endpoints.txt" >> "$report_md" 2>/dev/null
        [[ $endpoints_found -gt 30 ]] && echo "... and $((endpoints_found - 30)) more" >> "$report_md"
        echo '```' >> "$report_md"
    fi

    # File locations
    cat >> "$report_md" << 'EOF'

---

## Output Files

| File | Description |
|------|-------------|
| `subdomains.txt` | All discovered subdomains |
| `clean_httpx.txt` | Live subdomains (HTTP probe) |
| `httpx.json` | Full HTTP probe data |
| `urls.txt` | All discovered URLs |
| `uro.txt` | Optimized/deduped URLs |
| `js.txt` | JavaScript file URLs |
| `categorized/` | URLs by vulnerability pattern |
| `ports/` | Port scan results |
| `js/analysis/` | JS analysis results |
| `permutations/` | Subdomain permutation results |

---

*Generated by zee-scanner*
EOF

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
    "urls_total": $urls_total,
    "urls_optimized": $urls_optimized,
    "js_files": $js_files,
    "endpoints_found": $endpoints_found,
    "secrets_found": $secrets_found
  },
  "high_priority": {
    "has_secrets": $([ "$secrets_found" -gt 0 ] && echo "true" || echo "false")
  },
  "tool_effectiveness": {
    "subdomains": {
      "subfinder": $tool_subfinder,
      "assetfinder": $tool_assetfinder,
      "findomain": $tool_findomain,
      "amass": $tool_amass,
      "crtsh": $tool_crtsh
    },
    "urls": {
      "waybackurls": $tool_waybackurls,
      "waymore": $tool_waymore,
      "gau": $tool_gau,
      "katana": $tool_katana,
      "gospider": $tool_gospider
    },
    "js_analysis": {
      "jsluice": $tool_jsluice,
      "linkfinder": $tool_linkfinder
    }
  }
}
EOF

    ok "Report saved to: $report_md"
    ok "JSON report saved to: $report_json"

    # Print summary to stdout
    echo
    echo "════════════════════════════════════════════════════════════"
    echo "  SCAN COMPLETE: $domain"
    echo "════════════════════════════════════════════════════════════"
    echo "  Subdomains: $subdomains_live live / $subdomains_total total"
    echo "  URLs: $urls_optimized optimized / $urls_total total"
    echo "  Ports: $ports_open open"
    echo "  JS Files: $js_files"
    echo "  Endpoints: $endpoints_found"
    [[ $secrets_found -gt 0 ]] && echo "  ⚠ SECRETS FOUND: $secrets_found"
    echo "════════════════════════════════════════════════════════════"
    echo "  Report: $report_md"
    echo "════════════════════════════════════════════════════════════"
    echo
}
