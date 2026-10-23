# Samples docker stats while a load test runs. Start this, then start k6 in another terminal.
param([int]$Seconds = 40)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$runDir = Join-Path $Root "docs\evidence\runs"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$out = Join-Path $runDir ("docker-stats-{0}.csv" -f (Get-Date).ToString("yyyyMMdd-HHmmss"))
"timestamp,name,cpu,mem" | Set-Content -Encoding utf8 $out

$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $lines = & docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}"
    foreach ($line in @($lines)) {
        if ($line) { Add-Content -Encoding utf8 $out "$stamp,$line" }
    }
    Start-Sleep -Seconds 2
}
Write-Host "Wrote $out"
