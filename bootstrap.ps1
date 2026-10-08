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
#  Setup: replace  <USER>  and  <REPO>  with your own GitHub repo.
#  Usage: irm <RAW_URL_OF_THIS_FILE> | iex
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$RAW = 'https://raw.githubusercontent.com/<USER>/<REPO>/main/install.ps1'

# Mirror order: direct raw first (fastest when reachable), then GitHub
# proxies, then jsDelivr CDN as the last resort for networks where
# raw.githubusercontent.com is blocked.
# Note: jsDelivr caches branch content for roughly 12 hours, so it may
# serve a slightly older install.ps1 right after you update the repo.
$SRCS = @(
    $RAW,
    'https://gh-proxy.com/' + $RAW,
    'https://ghproxy.net/' + $RAW,
    'https://cdn.jsdelivr.net/gh/<USER>/<REPO>@main/install.ps1',
    'https://fastly.jsdelivr.net/gh/<USER>/<REPO>@main/install.ps1'
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
Write-Host 'Want to read it before running?' -ForegroundColor Yellow
Write-Host "  notepad `"$DST`"" -ForegroundColor Yellow
Write-Host ''
Write-Host 'Executing installer ...' -ForegroundColor Cyan
Write-Host ''

& $DST
