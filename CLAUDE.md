# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zee Scanner is a bash-based bug bounty reconnaissance automation tool that orchestrates multiple security tools in a pipeline. It automates subdomain enumeration, probing, port scanning, URL discovery, sensitive file hunting, and JavaScript analysis.

## Running the Scanner

```bash
./scan.sh <foldername> <domain> [--threads N] [--yes-js y|n] [--yes-ports y|n]
```

Example: `./scan.sh acme acme.com --threads 80 --yes-js n --yes-ports y`

Output is written to `$HACK/<foldername>` (defaults to `~/HACK/<foldername>`).

## Architecture

The scanner uses a modular architecture with shell scripts:

```
scan.sh              # Main entry point - orchestrates the pipeline
lib/
  colors.sh          # Terminal output helpers (info, ok, warn, err, banner)
  utils.sh           # Utilities (ensure_dir, prompt_yn, run)
modules/
  subdomains.sh      # Passive enumeration (subfinder, assetfinder, findomain, amass, crt.sh)
  probing.sh         # HTTP probing with httpx, outputs JSON + clean URL list
  ports.sh           # Port scanning with naabu, categorized port lists
  permutation.sh     # Subdomain permutation (alterx, dnsgen, gotator) + DNS resolution
  urls.sh            # URL discovery (waybackurls, waymore, gau, katana, gospider)
  categorize.sh      # GF pattern matching + unfurl extraction
  sensitive.sh       # Sensitive file/path discovery with ffuf and backupfinder
  js.sh              # JS download, beautification, endpoint extraction (jsluice, LinkFinder)
  report.sh          # Markdown + JSON report generation
```

### Pipeline Flow

1. **subdomains_step**: Parallel passive enumeration, wildcard detection
2. **probe_step**: httpx probing, generates `httpx.json` and `clean_httpx.txt`
3. **ports_step** (optional): naabu scan on categorized ports, httpx probe results
4. **permutation_step**: Generate and resolve permutations, append new discoveries
5. **urls_step**: Passive + active URL collection, uro optimization
6. **categorize_step**: GF patterns (sqli, xss, ssrf, etc.), unfurl extraction
7. **sensitive_step**: Sensitive file URLs, common paths via ffuf, backup finder
8. **js_step** (optional): Download JS, extract endpoints/secrets
9. **report_step**: Generate `report.md` and `report.json`

### Key Patterns

- Modules run tools in parallel using subshells with `&` and `wait_jobs` (reports failures)
- Domain values in grep/regex are escaped via `sed` to prevent regex injection (e.g. dots)
- Most tools output JSON for structured data (`httpx.json`, `ffuf_results.json`)
- Human-readable formats are derived from JSON using `jq`
- `$HEADER` variable is added to HTTP requests (defined in `lib/utils.sh`)
- Threads/concurrency controlled by `$THREADS` variable (default 50, override with `--threads`)
- All output is logged to `$OUTDIR/scan.log` with timestamps via `_log()` in `lib/colors.sh`
- Resume state uses atomic writes (temp+mv) and validates output files on resume
- Report includes per-tool effectiveness metrics (how many results each tool found)

## Environment Variables

- `HACK`: Base output directory (default: `~/HACK`)
- `SCAN_THREADS`: Default thread count
- `TOOLS`: Path to supporting utilities like LinkFinder
- `HEADER`: Custom HTTP header for probing tools

## Required External Tools

Enumeration: subfinder, assetfinder, findomain, amass, curl, jq
DNS: dnsgen, dnsx, alterx, gotator
Probing: httpx, naabu
URLs: waybackurls, waymore, gau, katana, gospider, uro
Categorization: gf, unfurl
Sensitive: ffuf, backupfinder
JS: curl, prettier, jsluice, trufflehog, python3 + LinkFinder
