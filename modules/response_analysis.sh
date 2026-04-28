#!/usr/bin/env bash
# shellcheck shell=bash

# HTTP Response Analysis - flag interesting findings from httpx.json

response_analysis_step() {
    local outdir="$1"
    local analysis_dir="$outdir/response_analysis"
    local httpx_json="$outdir/httpx_pretty.json"

    ok "Analyzing HTTP responses..."

    if [[ ! -s "$httpx_json" ]]; then
        warn "httpx_pretty.json not found; skipping response analysis"
        return 0
    fi

    ensure_dir "$analysis_dir"

    # 1. Interesting status codes (401, 403, 405, 500, 502, 503)
    jq -r '.[] | select(.status_code == 401 or .status_code == 403 or .status_code == 405 or
                   .status_code == 500 or .status_code == 502 or .status_code == 503)
        | "\(.url) [\(.status_code)]"' "$httpx_json" \
        > "$analysis_dir/interesting_status_codes.txt" 2>/dev/null &

    # 2. Tech stack summary
    jq -r '.[] | select(.tech != null and (.tech | length > 0))
        | "\(.url) -> \(.tech | join(", "))"' "$httpx_json" \
        > "$analysis_dir/tech_stack.txt" 2>/dev/null &

    wait_jobs "response_analysis"

    # Remove empty files
    find "$analysis_dir" -name "*.txt" -empty -delete 2>/dev/null

    # Print summary
    local interesting tech
    interesting=$([[ -f "$analysis_dir/interesting_status_codes.txt" ]] && wc -l < "$analysis_dir/interesting_status_codes.txt" || echo 0)
    tech=$([[ -f "$analysis_dir/tech_stack.txt" ]] && wc -l < "$analysis_dir/tech_stack.txt" || echo 0)

    [[ $interesting -gt 0 ]] && info "Interesting status codes: $interesting"
    [[ $tech -gt 0 ]] && info "Tech stack detected on: $tech hosts"

    ok "Response analysis complete -> $analysis_dir"
}
