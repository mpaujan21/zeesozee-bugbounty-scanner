# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zee Scanner is a bash-based bug bounty reconnaissance automation tool that orchestrates multiple security tools in a pipeline. It automates subdomain enumeration, probing, port scanning, URL discovery, JavaScript analysis, subdomain takeover detection, and screenshot capture.

## Running the Scanner

```bash
./scan.sh <foldername> <domain> [--threads N] [--yes-js y|n] [--yes-ports y|n] [--yes-screenshots y|n]
```

Example: `./scan.sh acme acme.com --threads 80 --yes-js n --yes-ports y --yes-screenshots y`

Output is written to `$HACK/programs/<foldername>` (defaults to `~/HACK/programs/<foldername>`).

## Architecture

The scanner uses a modular architecture with shell scripts:

```
scan.sh              # Main entry point - orchestrates the pipeline
lib/
  colors.sh          # Terminal output helpers (info, ok, warn, err, banner)
  utils.sh           # Utilities (ensure_dir, prompt_yn, run)
modules/
  subdomains.sh      # Passive enumeration (subfinder -all, assetfinder, findomain, amass, chaos) + recursive enum
  probing.sh         # HTTP probing with httpx, outputs JSON + clean URL list
  ports.sh           # Port scanning with rustscan, categorized port lists
  permutation.sh     # Subdomain permutation (alterx, dnsgen, gotator) + DNS resolution
  urls.sh            # URL discovery (waybackurls, waymore, gau, katana, gospider)
  categorize.sh      # GF pattern matching + unfurl extraction
  js.sh              # JS download, beautification, endpoint extraction (jsluice, LinkFinder)
  takeover.sh        # Subdomain takeover detection via dangling CNAME fingerprints
  screenshots.sh     # Screenshot capture with gowitness
  delta.sh           # Delta/diff scanning — highlights new findings between scans
  report.sh          # Markdown + JSON report generation
```

### Pipeline Flow

1. **subdomains_step**: Parallel passive enumeration, wildcard detection
2. **probe_step**: httpx probing on configurable ports, generates `httpx_pretty.json` and `clean_httpx.txt`; extracts `cdn_hosts.txt` and `shared_ips.txt`; optional ffuf vhost sweep on shared IPs
3. **takeover_step**: Check subdomains for dangling CNAMEs (configurable, default on)
4. **ports_step** (optional): rustscan scan on categorized ports, httpx probe results
5. **screenshots_step** (optional): gowitness screenshot capture of live hosts
6. **permutation_step**: Generate and resolve permutations, append new discoveries
7. **urls_step**: Passive + active URL collection, uro optimization
8. **categorize_step**: GF patterns (sqli, xss, ssrf, etc.), unfurl extraction
9. **js_step** (optional): Download JS, extract endpoints/secrets
10. **report_step**: Generate `report.md` and `report.json`
11. **delta_step**: Compare against previous scan, generate `delta.md` and `delta.json`

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
- Delta snapshots stored in `$OUTDIR/.snapshots/` with timestamped directories

## Environment Variables

- `HACK`: Base output directory (default: `~/HACK`)
- `SCAN_THREADS`: Default thread count
- `TOOLS`: Path to supporting utilities like LinkFinder
- `HEADER`: Custom HTTP header for probing tools
- `CHAOS_PDCP_API_KEY`: ProjectDiscovery API key for Chaos dataset (optional, skipped if unset)

## Configuration Toggles

- `ENABLE_TAKEOVER`: Enable subdomain takeover detection (default: true)
- `ENABLE_SCREENSHOTS`: Enable screenshot capture (default: true)
- `ENABLE_JSHUNTER`: Enable JShunter JS analysis (JWT/Firebase/GraphQL/params, default: true)
- `HTTPX_PORTS`: Ports probed by httpx (default: `80,443,8080,8443,8000,3000,8888,9090,4443,5000`)
- `ENABLE_VHOST`: Enable ffuf vhost sweep on shared IPs (default: true, requires ffuf)
- `VHOST_MAX_IPS`: Max shared IPs to run vhost sweep against (default: 5)
- `ENABLE_CHAOS`: Enable Chaos dataset source (default: true, requires `CHAOS_PDCP_API_KEY`)
- `ENABLE_RECURSIVE_ENUM`: Re-run subfinder on high-value zones (dev/staging/internal/etc.) found in initial pass (default: true)
- `RECURSIVE_ENUM_MAX_ZONES`: Max zones to recurse into (default: 5)

## Required External Tools

Enumeration: subfinder, assetfinder, findomain, amass, chaos, jq
DNS: dnsgen, dnsx, alterx, gotator
Probing: httpx, rustscan, ffuf (optional, for vhost)
URLs: waybackurls, waymore, gau, katana, gospider, uro
Categorization: gf, unfurl
JS: curl, prettier, jsluice, trufflehog, python3 + LinkFinder, jshunter
Optional: gowitness (screenshots)
