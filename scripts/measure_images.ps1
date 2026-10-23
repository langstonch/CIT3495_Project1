# Builds the C3 baseline and optimized images and prints size and build time.
# Default is --no-cache so the two Dockerfiles are comparable. Pass -UseCache for a quicker rerun.
param([switch]$UseCache)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$cacheArg = @("--no-cache")
if ($UseCache) { $cacheArg = @() }

function Build-Measured([string]$Label, [string]$File, [string]$Context, [string]$Tag) {
    Write-Host ""
    Write-Host "Building $Label ($File)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & docker build @cacheArg -f $File -t $Tag $Context
    if ($LASTEXITCODE -ne 0) { throw "docker build failed for $Tag" }
    $sw.Stop()
    $bytes = [int64](& docker image inspect $Tag --format "{{.Size}}")
    return [pscustomobject]@{
        Label   = $Label
        File    = $File
        MB      = [math]::Round($bytes / 1MB, 1)
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

$rows = @(
    (Build-Measured "analytics baseline" "analytics/Dockerfile.baseline" "analytics" "cit3495-analytics:baseline"),
    (Build-Measured "analytics optimized" "analytics/Dockerfile" "analytics" "cit3495-analytics:optimized"),
    (Build-Measured "showresults baseline" "showresults/Dockerfile.baseline" "showresults" "cit3495-showresults:baseline"),
    (Build-Measured "showresults optimized" "showresults/Dockerfile" "showresults" "cit3495-showresults:optimized")
)

Write-Host ""
Write-Host "| Image | Dockerfile | Size (MB) | Build (s) |"
Write-Host "|---|---|---:|---:|"
foreach ($row in $rows) {
    Write-Host ("| {0} | ``{1}`` | {2} | {3} |" -f $row.Label, $row.File, $row.MB, $row.Seconds)
}
Write-Host ""
Write-Host "Copy this table into docs/evidence/C3-image-optimization.md."
Write-Host "These tags are not the images Compose runs. Compose keeps using analytics/Dockerfile and showresults/Dockerfile."
