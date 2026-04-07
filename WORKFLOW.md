# Zee Scanner - Workflow

## How It Works

```
Domain Input
     |
     v
+------------------+
| 1. Subdomains    |  Find all subdomains (subfinder, assetfinder, findomain, amass, crt.sh)
+------------------+
     |
     v
+------------------+
| 2. Probing       |  Check which subdomains are alive (httpx)
+------------------+
     |
     +------------ (optional) -----+
     |                              v
     |                    +------------------+
     |                    | 3. Port Scan     |  Scan open ports on live hosts (rustscan)
     |                    +------------------+
     |                              |
     +<----------------------------+
     |
     v
+------------------+
| 4. URL Discovery |  Collect all known URLs (waybackurls, waymore, gau, katana, gospider)
+------------------+
     |
     v
+------------------+
| 5. Categorize    |  Sort URLs by vuln type: sqli, xss, ssrf, lfi, etc. (gf + unfurl)
+------------------+
     |
     v
+------------------+
| 6. Sensitive     |  Find exposed files & backup files (ffuf, backupfinder)
+------------------+
     |
     +------------ (optional) -----+
     |                              v
     |                    +------------------+
     |                    | 7. JS Analysis   |  Download JS, extract endpoints & secrets
     |                    +------------------+
     |                              |
     +<----------------------------+
     |
     v
+------------------+
| 8. Report        |  Generate report.md + report.json
+------------------+
```

## Quick Start

```bash
# Basic scan
./scan.sh myproject target.com

# Fast scan (skip JS + ports)
./scan.sh myproject target.com --yes-js n --yes-ports n

# Full scan with more threads
./scan.sh myproject target.com --threads 100 --yes-js y --yes-ports y
```

## What Each Step Does

### 1. Subdomains
Runs 5 tools in parallel to find subdomains. Also checks for wildcard DNS. Output: `subdomains.txt`

### 2. Probing
Sends HTTP requests to all subdomains to find which ones are alive. Collects status codes, titles, technologies, IPs. Output: `httpx.json`, `clean_httpx.txt`

### 3. Port Scan (optional)
Scans common ports (web, dev, admin, API, database, CI/CD) on non-CDN hosts. Probes discovered ports for HTTP services. Output: `ports/`

### 4. URL Discovery
Collects URLs from web archives and crawlers. Filters to target scope only. Removes duplicates with `uro`. Output: `urls.txt`, `uro.txt`

### 5. Categorize
Sorts URLs into vulnerability categories using GF patterns (sqli, xss, ssrf, redirect, rce, lfi, etc.). Extracts URL components with unfurl. Output: `categorized/`

### 6. Sensitive Files
Finds sensitive file URLs (configs, backups, databases). Fuzzes common paths on all live hosts with ffuf. Runs backupfinder on each host. Output: `sensitive/`

### 7. JS Analysis (optional)
Downloads JavaScript files, beautifies them, then extracts endpoints and secrets using jsluice, LinkFinder, and trufflehog. Output: `js/`

### 8. Report
Generates a markdown summary with stats and high-priority findings, plus a JSON export. Output: `report.md`, `report.json`

## Resume

If the scan gets interrupted, just run the same command again. It picks up where it left off. Use `--force-restart` to start fresh.

## Output

Everything goes to `~/HACK/<foldername>/`. The most useful files:

| File | What's in it |
|------|-------------|
| `subdomains.txt` | All found subdomains |
| `clean_httpx.txt` | Live subdomains |
| `httpx.json` | Detailed probe data |
| `urls.txt` | All discovered URLs |
| `categorized/*.txt` | URLs sorted by vuln type |
| `sensitive/` | Exposed files & paths |
| `js/analysis/` | Endpoints & secrets from JS |
| `report.md` | Final summary report |
