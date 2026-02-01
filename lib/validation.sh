#!/usr/bin/env bash
# shellcheck shell=bash

# Tool availability checking
check_required_tools() {
    local missing=()

    # Core tools
    local core_tools=(curl jq)

    # Subdomain enumeration tools
    local subdomain_tools=(subfinder assetfinder findomain amass dig)

    # DNS tools
    local dns_tools=(dnsx dnsgen alterx gotator)

    # Probing and scanning tools
    local probing_tools=(httpx naabu)

    # URL discovery tools
    local url_tools=(waybackurls waymore gau katana gospider uro)

    # Categorization tools
    local categorize_tools=(gf unfurl)

    # Sensitive file discovery tools
    local sensitive_tools=(ffuf backupfinder)

    # JS analysis tools (optional - will warn but not fail)
    local optional_js_tools=(jsluice prettier trufflehog python3)

    # Combine all required tools
    local all_required=("${core_tools[@]}" "${subdomain_tools[@]}" "${dns_tools[@]}"
                       "${probing_tools[@]}" "${url_tools[@]}" "${categorize_tools[@]}"
                       "${sensitive_tools[@]}")

    # Check required tools
    for tool in "${all_required[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    # Report missing required tools
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools:"
        for tool in "${missing[@]}"; do
            err "  - $tool"
        done
        info "Install missing tools before running the scanner"
        return 1
    fi

    # Check optional tools (warn only)
    local missing_optional=()
    for tool in "${optional_js_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_optional+=("$tool")
        fi
    done

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Optional tools missing (JS analysis may be limited):"
        for tool in "${missing_optional[@]}"; do
            warn "  - $tool"
        done
    fi

    ok "All required tools are available"
    return 0
}

# Validate domain format
validate_domain() {
    local domain="$1"

    # Check for empty domain
    if [[ -z "$domain" ]]; then
        err "Domain cannot be empty"
        return 1
    fi

    # Basic domain regex: alphanumeric, hyphens, dots
    # Allows: example.com, sub.example.com, sub-domain.example.co.uk
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        err "Invalid domain format: $domain"
        err "Domain must contain only alphanumeric characters, hyphens, and dots"
        return 1
    fi

    # Check for valid TLD (at least one dot)
    if [[ ! "$domain" =~ \. ]]; then
        warn "Domain '$domain' has no TLD - this may not be a valid domain"
    fi

    return 0
}

# Validate thread count
validate_threads() {
    local threads="$1"

    # Check if numeric
    if [[ ! "$threads" =~ ^[0-9]+$ ]]; then
        err "Thread count must be a positive integer, got: $threads"
        return 1
    fi

    # Check range (1-1000)
    if [[ $threads -lt 1 || $threads -gt 1000 ]]; then
        err "Thread count must be between 1 and 1000, got: $threads"
        return 1
    fi

    # Warn if very high
    if [[ $threads -gt 200 ]]; then
        warn "High thread count ($threads) may cause rate limiting or system issues"
    fi

    return 0
}

# Validate folder name for safe filesystem operations
validate_foldername() {
    local foldername="$1"

    # Check for empty
    if [[ -z "$foldername" ]]; then
        err "Folder name cannot be empty"
        return 1
    fi

    # Check for path traversal attempts
    if [[ "$foldername" =~ \.\. ]] || [[ "$foldername" =~ ^/ ]] || [[ "$foldername" =~ ^~ ]]; then
        err "Invalid folder name: $foldername"
        err "Folder name cannot contain '..' or start with '/' or '~'"
        return 1
    fi

    # Check for invalid characters (allow alphanumeric, dash, underscore, dot)
    if [[ ! "$foldername" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        err "Invalid folder name: $foldername"
        err "Folder name must contain only alphanumeric characters, dots, dashes, and underscores"
        return 1
    fi

    return 0
}

# Validate file exists and is readable
validate_file_exists() {
    local file="$1"
    local description="${2:-File}"

    if [[ ! -f "$file" ]]; then
        warn "$description not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        err "$description not readable: $file"
        return 1
    fi

    return 0
}

# Validate file exists and has content
validate_file_has_content() {
    local file="$1"
    local description="${2:-File}"

    if ! validate_file_exists "$file" "$description"; then
        return 1
    fi

    if [[ ! -s "$file" ]]; then
        warn "$description is empty: $file"
        return 1
    fi

    return 0
}

# Validate directory exists and is writable
validate_directory() {
    local dir="$1"
    local description="${2:-Directory}"

    if [[ ! -d "$dir" ]]; then
        warn "$description does not exist: $dir"
        return 1
    fi

    if [[ ! -w "$dir" ]]; then
        err "$description not writable: $dir"
        return 1
    fi

    return 0
}
