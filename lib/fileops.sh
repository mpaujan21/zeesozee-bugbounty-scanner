#!/usr/bin/env bash
# shellcheck shell=bash

# Validate JSON file integrity
validate_json() {
    local file="$1"
    local description="${2:-JSON file}"

    # Check file exists and has content
    if [[ ! -f "$file" ]]; then
        warn "$description not found: $file"
        return 1
    fi

    if [[ ! -s "$file" ]]; then
        warn "$description is empty: $file"
        return 1
    fi

    # Validate JSON syntax
    if ! jq empty "$file" 2>/dev/null; then
        err "$description has invalid JSON syntax: $file"
        return 1
    fi

    return 0
}

# Safe jq execution with error handling
safe_jq() {
    local filter="$1"
    local file="$2"
    local description="${3:-JSON file}"

    # Validate JSON first
    if ! validate_json "$file" "$description"; then
        return 1
    fi

    # Execute jq with error handling
    if ! jq -r "$filter" "$file" 2>/dev/null; then
        err "Failed to parse $description with filter: $filter"
        return 1
    fi

    return 0
}

# Count lines in file, return 0 if missing or empty
count_lines_safe() {
    local file="$1"

    if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
        echo "0"
        return 0
    fi

    wc -l < "$file" 2>/dev/null || echo "0"
}

# Check if file has content (exists and non-empty)
has_content() {
    local file="$1"
    [[ -f "$file" && -s "$file" ]]
}

# Safe file removal with verification
safe_rm() {
    local file="$1"

    if [[ ! -e "$file" ]]; then
        return 0  # Already doesn't exist
    fi

    if rm "$file" 2>/dev/null; then
        return 0
    else
        warn "Failed to remove file: $file"
        return 1
    fi
}

# Atomic write to file (write to temp, then move)
atomic_write() {
    local content="$1"
    local target_file="$2"
    local temp_file="${target_file}.tmp.$$"

    # Write to temp file
    if ! echo "$content" > "$temp_file" 2>/dev/null; then
        err "Failed to write to temporary file: $temp_file"
        return 1
    fi

    # Move to target
    if ! mv "$temp_file" "$target_file" 2>/dev/null; then
        err "Failed to move temporary file to target: $target_file"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    return 0
}

# Extract URLs from httpx JSON (centralized to avoid duplication)
extract_httpx_urls() {
    local json_file="$1"
    local output_file="$2"

    if ! validate_json "$json_file" "httpx JSON"; then
        return 1
    fi

    # Extract URLs from responses (2xx, 3xx redirects, 401, 403)
    if ! jq -r 'select((.status_code >= 200 and .status_code < 400) or .status_code == 401 or .status_code == 403) | .url' "$json_file" > "$output_file" 2>/dev/null; then
        err "Failed to extract URLs from httpx JSON"
        return 1
    fi

    return 0
}

# Extract hostnames from httpx JSON
extract_httpx_hosts() {
    local json_file="$1"
    local output_file="$2"

    if ! validate_json "$json_file" "httpx JSON"; then
        return 1
    fi

    # Extract unique hostnames
    if ! jq -r 'select(.host) | .host' "$json_file" | sort -u > "$output_file" 2>/dev/null; then
        err "Failed to extract hosts from httpx JSON"
        return 1
    fi

    return 0
}

# Validate ffuf JSON output
validate_ffuf_json() {
    local file="$1"

    if ! validate_json "$file" "ffuf results"; then
        return 1
    fi

    # Check for results array
    if ! jq -e '.results' "$file" >/dev/null 2>&1; then
        warn "ffuf JSON missing 'results' field: $file"
        return 1
    fi

    return 0
}

# Extract ffuf results to readable format
extract_ffuf_results() {
    local json_file="$1"
    local output_file="$2"

    if ! validate_ffuf_json "$json_file"; then
        return 1
    fi

    # Extract URL, status, length, words
    if ! jq -r '.results[] | "\(.url) [Status: \(.status)] [Length: \(.length)] [Words: \(.words)]"' \
        "$json_file" > "$output_file" 2>/dev/null; then
        err "Failed to extract ffuf results"
        return 1
    fi

    return 0
}
