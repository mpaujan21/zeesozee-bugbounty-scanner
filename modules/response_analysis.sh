#!/usr/bin/env bash
# shellcheck shell=bash

# HTTP Response Analysis - flag interesting findings from httpx.json

response_analysis_step() {
    local outdir="$1"
    local analysis_dir="$outdir/response_analysis"
    local httpx_json="$outdir/httpx.json"

    ok "Analyzing HTTP responses..."

    if ! validate_json "$httpx_json" "httpx results"; then
        warn "httpx.json not found or invalid; skipping response analysis"
        return 0
    fi

    ensure_dir "$analysis_dir"

    # 1. 403 Bypass Candidates
    jq -r 'select(.status_code == 403) | .url' "$httpx_json" \
        > "$analysis_dir/403_bypass_candidates.txt" 2>/dev/null &

    # 2. CORS Wildcard misconfig
    # httpx normalizes header keys to lowercase with underscores
    jq -r '
        select(.header != null) |
        select(.header.access_control_allow_origin != null) |
        select(.header.access_control_allow_origin | test("\\*"))
        | .url' "$httpx_json" \
        > "$analysis_dir/cors_wildcard.txt" 2>/dev/null &

    # 3. Missing security headers
    _check_missing_headers "$httpx_json" "$analysis_dir" &

    # 4. Interesting status codes (401, 405, 500, 502, 503)
    jq -r 'select(.status_code == 401 or .status_code == 405 or
                   .status_code == 500 or .status_code == 502 or .status_code == 503)
        | "\(.url) [\(.status_code)]"' "$httpx_json" \
        > "$analysis_dir/interesting_status_codes.txt" 2>/dev/null &

    # 5. Tech stack summary
    jq -r 'select(.tech != null and (.tech | length > 0))
        | "\(.url) -> \(.tech | join(", "))"' "$httpx_json" \
        > "$analysis_dir/tech_stack.txt" 2>/dev/null &

    wait_jobs "response_analysis"

    # Remove empty files
    find "$analysis_dir" -name "*.txt" -empty -delete 2>/dev/null

    # Print summary
    local f403 cors missing_hdr interesting tech
    f403=$(wc -l < "$analysis_dir/403_bypass_candidates.txt" 2>/dev/null || echo 0)
    cors=$(wc -l < "$analysis_dir/cors_wildcard.txt" 2>/dev/null || echo 0)
    missing_hdr=$(wc -l < "$analysis_dir/missing_security_headers.txt" 2>/dev/null || echo 0)
    interesting=$(wc -l < "$analysis_dir/interesting_status_codes.txt" 2>/dev/null || echo 0)
    tech=$(wc -l < "$analysis_dir/tech_stack.txt" 2>/dev/null || echo 0)

    [[ $f403 -gt 0 ]] && info "403 bypass candidates: $f403"
    [[ $cors -gt 0 ]] && warn "CORS wildcard (*) found: $cors hosts"
    [[ $missing_hdr -gt 0 ]] && info "Hosts missing security headers: $missing_hdr"
    [[ $interesting -gt 0 ]] && info "Interesting status codes: $interesting"
    [[ $tech -gt 0 ]] && info "Tech stack detected on: $tech hosts"

    ok "Response analysis complete -> $analysis_dir"
}

_check_missing_headers() {
    local httpx_json="$1" analysis_dir="$2"
    local output="$analysis_dir/missing_security_headers.txt"

    # httpx normalizes header keys to lowercase with underscores
    jq -r '
        select(.header != null) |
        . as $entry |
        ($entry.header | keys) as $hdr_keys |
        [
            (if ($hdr_keys | index("strict_transport_security")) == null then "HSTS" else empty end),
            (if ($hdr_keys | index("x_content_type_options")) == null then "X-Content-Type-Options" else empty end),
            (if ($hdr_keys | index("content_security_policy")) == null then "CSP" else empty end)
        ] | select(length > 0) |
        "\($entry.url) missing: \(join(", "))"
    ' "$httpx_json" > "$output" 2>/dev/null || true
}
