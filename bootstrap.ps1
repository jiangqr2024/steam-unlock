# ---- download loop ----
# Mirror note: raw.githubusercontent.com serves a cached copy for a few minutes
# after a push, so the *first* mirror can legitimately hand back a stale
# install.ps1. That is why the hash check lives inside this loop: a mismatch
# just means "this source is stale", not "we are under attack". The next source
# is tried immediately. Only when every source fails do we refuse to run.
#
# Order: direct raw first (fastest when fresh), then GitHub proxies, then
# jsDelivr (caches ~12h, so it may also lag right after an update).
$RAW = 'https://raw.githubusercontent.com/jiangqr2024/steam-unlock/main/install.ps1'
#
# Expected SHA256 of install.ps1. Maintained by sync-hashes.ps1 - run that
# BEFORE pushing install.ps1, and push this file first.
$INSTALL_SHA = '176F6BDEBCC010715324FBF4A7E97523C90B89DD173D6500CD332835E412932B'
#
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
$h = $null
$sz = 0
$sawStale = $false
$sawTooSmall = $false

foreach ($s in $SRCS) {
    $label = $s
    if ($label.Length -gt 70) { $label = $label.Substring(0, 67) + '...' }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Write-Host ("  attempt {0}/2 : {1}" -f $attempt, $label) -ForegroundColor DarkGray
            $null = Invoke-WebRequest -Uri $s -OutFile $DST -UseBasicParsing -TimeoutSec 45
            $sz = (Get-Item $DST).Length
            if ($sz -lt $MIN) {
                Write-Host '                 response too small, will retry' -ForegroundColor DarkYellow
                $sawTooSmall = $true
                continue
            }
            $h = (Get-FileHash $DST -Algorithm SHA256).Hash
            if ($h -eq $INSTALL_SHA) { $used = $s; break }
            # Wrong hash: almost always a stale CDN copy. Report and move on.
            $sawStale = $true
            Write-Host ("                 stale copy ({0}...), trying next source" -f $h.Substring(0, 12)) -ForegroundColor DarkYellow
            break
        }
        catch {
            if ($attempt -eq 2) {
                $msg = ''
                if ($_.Exception) { $msg = $_.Exception.Message }
                Write-Host ("                 failed: {0}" -f $msg) -ForegroundColor DarkGray
            }
            Start-Sleep -Milliseconds 900
        }
    }
    if ($used) { break }
}

if (-not $used) {
    Write-Host ''
    Write-Host '[x] Could not obtain a verified install.ps1.' -ForegroundColor Red
    if ($sawStale) {
        Write-Host '    Every mirror that answered served a build that does not match the' -ForegroundColor Yellow
        Write-Host '    expected SHA256. Most likely the CDN is still serving the previous' -ForegroundColor Yellow
        Write-Host '    version. Wait 5-10 minutes and run the command again.' -ForegroundColor Yellow
        Write-Host ("    expected: {0}" -f $INSTALL_SHA) -ForegroundColor Yellow
        Write-Host ("    got     : {0}" -f $h) -ForegroundColor Yellow
    }
    elseif ($sawTooSmall) {
        Write-Host '    Mirrors answered, but every response was too small to be the installer.' -ForegroundColor Yellow
    }
    else {
        Write-Host '    No mirror answered. Check your network or proxy, then retry.' -ForegroundColor Yellow
    }
    Write-Host ("    The last download is kept at: {0}" -f $DST) -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "[+] Mirror used : $used" -ForegroundColor Green
Write-Host "[+] Saved to    : $DST" -ForegroundColor Green
Write-Host "[+] Size        : $sz bytes" -ForegroundColor Green
Write-Host "[+] SHA256      : $h" -ForegroundColor Green
Write-Host "[+] Integrity   : matches the hash pinned in this file" -ForegroundColor Green
Write-Host ''
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