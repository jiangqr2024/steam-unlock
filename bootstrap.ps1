# ============================================================
#  Steam Unlock Installer - Bootstrap
# ============================================================
#  This file is short on purpose so you can read all of it.
#  It only does three things:
#     1) downloads the full installer, trying several mirrors
#     2) prints the mirror used, the path and the SHA256
#     3) runs it
#
#  It does NOT hide anything. It does NOT touch antivirus settings.
#  It does NOT use packed / encrypted / memory-loaded payloads.
#  The only remote fetch is install.ps1 from the fixed URLs below.
#
#  Setup: replace  jiangqr2024  and  steam-unlock  with your own GitHub repo.
#  Usage: irm <RAW_URL_OF_THIS_FILE> | iex
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$RAW = 'https://raw.githubusercontent.com/jiangqr2024/steam-unlock/main/install.ps1'

# Mirror order: direct raw first (fastest when reachable), then GitHub
# proxies, then jsDelivr CDN as the last resort for networks where
# raw.githubusercontent.com is blocked.
# Note: jsDelivr caches branch content for roughly 12 hours, so it may
# serve a slightly older install.ps1 right after you update the repo.
$SRCS = @(
    $RAW,
    'https://gh-proxy.com/' + $RAW,
    'https://ghproxy.net/' + $RAW,
    'https://cdn.jsdelivr.net/gh/jiangqr2024/steam-unlock@main/install.ps1',
    'https://fastly.jsdelivr.net/gh/jiangqr2024/steam-unlock@main/install.ps1'
)

$DST = Join-Path $env:TEMP 'ost-install.ps1'
$MIN = 2000

Write-Host ''
Write-Host '=== Steam Unlock Installer - bootstrap ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Fetching installer (will try multiple mirrors) ...' -ForegroundColor Gray

$used = $null
foreach ($s in $SRCS) {
    $label = $s
    if ($label.Length -gt 70) { $label = $label.Substring(0, 67) + '...' }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Write-Host ("  attempt {0}/2 : {1}" -f $attempt, $label) -ForegroundColor DarkGray
            $null = Invoke-WebRequest -Uri $s -OutFile $DST -UseBasicParsing -TimeoutSec 45
            if ((Get-Item $DST).Length -ge $MIN) { $used = $s; break }
            Write-Host '                 response too small, will retry' -ForegroundColor DarkYellow
        }
        catch {
            if ($attempt -eq 2) { Write-Host '                 failed' -ForegroundColor DarkGray }
            Start-Sleep -Milliseconds 900
        }
    }
    if ($used) { break }
}

if (-not $used) {
    Write-Host ''
    Write-Host '[x] All mirrors failed.' -ForegroundColor Red
    Write-Host '    Check your network or proxy, then run the command again.' -ForegroundColor Red
    return
}

$h = (Get-FileHash $DST -Algorithm SHA256).Hash
$sz = (Get-Item $DST).Length

Write-Host ''
Write-Host "[+] Mirror used : $used" -ForegroundColor Green
Write-Host "[+] Saved to    : $DST" -ForegroundColor Green
Write-Host "[+] Size        : $sz bytes" -ForegroundColor Green
Write-Host "[+] SHA256      : $h" -ForegroundColor Green
Write-Host ''
# ---- install.ps1 integrity check ----
# Why this exists: this script feeds install.ps1 to iex. iex is not bound by
# ExecutionPolicy, which is exactly why it works on locked-down machines - and
# also why a swapped install.ps1 would go unnoticed. So the expected hash is
# pinned here. Maintain it with sync-hashes.ps1 BEFORE uploading.
# Fix: stop, save the file the mirror gave you, compare its hash, and check:
#      https://github.com/jiangqr2024/steam-unlock/issues
$INSTALL_SHA = '5C7FC1E4E77E77ED92B16650028F56F48BC2898734805D71E8BD6621105C7442'
if ($h -ne $INSTALL_SHA) {
    Write-Host ''
    Write-Host '[x] install.ps1 SHA256 mismatch - NOT running it.' -ForegroundColor Red
    Write-Host '    expected: ' -NoNewline -ForegroundColor Red; Write-Host $INSTALL_SHA -ForegroundColor Red
    Write-Host '    got     : ' -NoNewline -ForegroundColor Red; Write-Host $h -ForegroundColor Red
    Write-Host '    The file is kept at the path above for inspection.' -ForegroundColor Yellow
    return
}

Write-Host 'Want to read it before running?' -ForegroundColor Yellow
Write-Host "  notepad `"$DST`"" -ForegroundColor Yellow
Write-Host ''
Write-Host 'Executing installer ...' -ForegroundColor Cyan
Write-Host ''

# Run via iex rather than the call operator "& $script":
# the call operator IS subject to ExecutionPolicy. Fresh Windows client installs
# default to Restricted, and even under RemoteSigned a script downloaded from the
# internet carries Mark-of-the-Web and gets blocked. iex runs a string, so it is
# unaffected. Verified: under Restricted, & fails and iex succeeds.
# NOTE: this file must stay pure ASCII with no BOM, because it is fed to iex by
# PowerShell 5.1, which would decode non-ASCII bytes using the ANSI code page.
iex (Get-Content $DST -Raw)
