#!/bin/bash
# Zee Scanner - Tool Installation Script
# Installs all required tools for the scanner

set -e

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"

info() { echo -e "${BLUE}[*] $*${RESET}"; }
ok() { echo -e "${GREEN}[+] $*${RESET}"; }
warn() { echo -e "${YELLOW}[!] $*${RESET}"; }
err() { echo -e "${RED}[!] $*${RESET}"; }

banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           ZEE SCANNER - TOOL INSTALLATION SCRIPT              ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

check_go() {
    if ! command -v go >/dev/null 2>&1; then
        err "Go is not installed. Please install Go 1.21+ first:"
        echo "  https://golang.org/doc/install"
        exit 1
    fi
    ok "Go is installed: $(go version)"
}

check_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "Python 3 is not installed"
        return 1
    fi
    ok "Python 3 is installed: $(python3 --version)"
}

install_go_tools() {
    info "Installing Go-based tools..."

    local tools=(
        # Subdomain enumeration
        "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
        "github.com/tomnomnom/assetfinder@latest"
        "github.com/projectdiscovery/chaos-client/cmd/chaos@latest"

        # DNS tools
        "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
        "github.com/Cgboal/SonarSearch/cmd/crobat@latest"

        # HTTP probing
        "github.com/projectdiscovery/httpx/cmd/httpx@latest"
        # naabu removed — replaced by rustscan (see install_rust_tools)

        # URL discovery
        "github.com/tomnomnom/waybackurls@latest"
        "github.com/lc/gau/v2/cmd/gau@latest"
        "github.com/projectdiscovery/katana/cmd/katana@latest"

        # Permutation
        "github.com/projectdiscovery/alterx/cmd/alterx@latest"
        "github.com/Josue87/gotator@latest"

        # Filtering & categorization
        "github.com/tomnomnom/unfurl@latest"
        "github.com/tomnomnom/gf@latest"
        "github.com/s0md3v/uro@latest"

        # Fuzzing
        "github.com/ffuf/ffuf/v2@latest"

        # JS analysis
        "github.com/BishopFox/jsluice/cmd/jsluice@latest"
    )

    for tool in "${tools[@]}"; do
        local tool_name=$(basename "$tool" | cut -d'@' -f1)
        info "Installing $tool_name..."
        if go install -v "$tool" 2>&1 | grep -v "^go: downloading"; then
            ok "Installed $tool_name"
        else
            warn "Failed to install $tool_name"
        fi
    done
}

install_rust_tools() {
    if ! command -v cargo >/dev/null 2>&1; then
        warn "Rust/Cargo not installed, skipping findomain"
        warn "Install from: https://rustup.rs/"
        return
    fi

    info "Installing Rust-based tools..."
    cargo install findomain 2>&1 | tail -1
    ok "Installed findomain"
    cargo install rustscan 2>&1 | tail -1
    ok "Installed rustscan"
}

install_python_tools() {
    if ! check_python; then
        warn "Skipping Python tools"
        return
    fi

    info "Installing Python-based tools..."

    # Install pip packages
    pip3 install --user waymore trufflehog 2>&1 | tail -5

    # Install LinkFinder
    local TOOLS="${TOOLS:-$HOME/tools}"
    mkdir -p "$TOOLS"

    if [[ ! -d "$TOOLS/LinkFinder" ]]; then
        info "Cloning LinkFinder..."
        git clone https://github.com/GerbenJavado/LinkFinder.git "$TOOLS/LinkFinder"
        pip3 install --user -r "$TOOLS/LinkFinder/requirements.txt" 2>&1 | tail -3
        ok "Installed LinkFinder"
    else
        ok "LinkFinder already installed"
    fi
}

install_external_tools() {
    info "Installing external tools..."

    # Install amass
    if ! command -v amass >/dev/null 2>&1; then
        info "Installing amass..."
        go install -v github.com/owasp-amass/amass/v4/...@master 2>&1 | tail -1
        ok "Installed amass"
    else
        ok "amass already installed"
    fi

    # Install gospider
    if ! command -v gospider >/dev/null 2>&1; then
        info "Installing gospider..."
        go install github.com/jaeles-project/gospider@latest 2>&1 | tail -1
        ok "Installed gospider"
    else
        ok "gospider already installed"
    fi

    # Install dnsgen
    if ! command -v dnsgen >/dev/null 2>&1 && check_python; then
        info "Installing dnsgen..."
        pip3 install --user dnsgen 2>&1 | tail -3
        ok "Installed dnsgen"
    elif command -v dnsgen >/dev/null 2>&1; then
        ok "dnsgen already installed"
    fi

    # Install backupfinder
    if ! command -v backupfinder >/dev/null 2>&1; then
        info "Installing backupfinder..."
        go install github.com/six2dez/backupfinder@latest 2>&1 | tail -1
        ok "Installed backupfinder"
    else
        ok "backupfinder already installed"
    fi

    # Install prettier (for JS beautification)
    if command -v npm >/dev/null 2>&1; then
        if ! command -v prettier >/dev/null 2>&1; then
            info "Installing prettier..."
            npm install -g prettier 2>&1 | tail -3
            ok "Installed prettier"
        else
            ok "prettier already installed"
        fi
    else
        warn "npm not found, skipping prettier"
    fi
}

install_wordlists() {
    info "Setting up GF patterns..."

    if [[ ! -d "$HOME/.gf" ]]; then
        mkdir -p "$HOME/.gf"
        git clone https://github.com/1ndianl33t/Gf-Patterns "$HOME/.gf/patterns" 2>&1 | tail -1
        cp "$HOME/.gf/patterns"/*.json "$HOME/.gf/" 2>/dev/null || true
        ok "Installed GF patterns"
    else
        ok "GF patterns already installed"
    fi
}

verify_installation() {
    info "Verifying installation..."

    local required_tools=(
        "subfinder" "assetfinder" "findomain" "amass"
        "httpx" "rustscan" "dnsx"
        "waybackurls" "gau" "katana" "gospider"
        "alterx" "dnsgen" "gotator"
        "gf" "unfurl" "ffuf"
        "curl" "jq"
    )

    local missing=()
    local installed=()

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            installed+=("$tool")
        else
            missing+=("$tool")
        fi
    done

    echo ""
    ok "Installed tools (${#installed[@]}/${#required_tools[@]}):"
    for tool in "${installed[@]}"; do
        echo "  ✓ $tool"
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        warn "Missing tools (${#missing[@]}):"
        for tool in "${missing[@]}"; do
            echo "  ✗ $tool"
        done
        echo ""
        warn "Some tools are missing. Run this script again or install manually."
        return 1
    else
        echo ""
        ok "All required tools are installed!"
        return 0
    fi
}

main() {
    banner

    info "This script will install all required tools for Zee Scanner"
    info "Installation directory: \$GOPATH/bin (usually ~/go/bin)"
    echo ""

    # Check prerequisites
    check_go

    # Ensure Go bin is in PATH
    if [[ ":$PATH:" != *":$HOME/go/bin:"* ]]; then
        warn "~/go/bin is not in your PATH"
        info "Add this to your ~/.bashrc or ~/.zshrc:"
        echo "  export PATH=\"\$HOME/go/bin:\$PATH\""
        echo ""
    fi

    # Install tools
    install_go_tools
    install_rust_tools
    install_python_tools
    install_external_tools
    install_wordlists

    # Verify
    verify_installation

    echo ""
    ok "Installation complete!"
    info "You may need to restart your shell or run: source ~/.bashrc"
}

main "$@"
