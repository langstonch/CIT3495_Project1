# Shows named volumes keep MySQL rows and MongoDB stats across container recreation.
# Requires the stack up. Does not pass -v to docker compose rm.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Category = "persist-check"
$Report = New-Object System.Collections.Generic.List[string]

function Say([string]$Line) {
    Write-Host $Line
    $Report.Add($Line) | Out-Null
}

function Invoke-Mysql([string]$Sql) {
    $out = $Sql | & docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N --batch "$MYSQL_DATABASE" 2>/dev/null'
    if ($LASTEXITCODE -ne 0) { throw "MySQL query failed" }
    return (("$out").Trim())
}

function Invoke-Mongo([string]$Js) {
    $out = & docker compose exec -T mongo mongosh --quiet analytics_db --eval $Js
    if ($LASTEXITCODE -ne 0) { throw "Mongo query failed: $Js" }
    return (("$out").Trim())
}

function Get-Cid([string]$Name) {
    $id = @(& docker compose ps -aq $Name | Where-Object { $_ -and $_.ToString().Trim() })
    if ($id.Count -eq 0) { return $null }
    return $id[0].ToString().Trim()
}

function Wait-Healthy([string[]]$Names, [int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $ready = $true
        foreach ($name in $Names) {
            $id = Get-Cid $name
            if (-not $id) { $ready = $false; continue }
            $status = (& docker inspect -f "{{.State.Status}}" $id).Trim()
            $health = (& docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $id).Trim()
            if ($status -ne "running" -or $health -ne "healthy") { $ready = $false }
        }
        if ($ready) { return [int][math]::Ceiling($sw.Elapsed.TotalSeconds) }
        Start-Sleep -Seconds 2
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return -1
}

function Get-Counts {
    $measurements = Invoke-Mysql "SELECT COUNT(*) FROM measurements;"
    $users = Invoke-Mysql "SELECT COUNT(*) FROM users;"
    $categoryRows = Invoke-Mysql "SELECT COUNT(*) FROM measurements WHERE category='$Category';"
    $statCount = Invoke-Mongo "const d = db.stats.findOne({category: '$Category'}); print(d ? d.count : 'missing');"
    $statDocs = Invoke-Mongo "print(db.stats.countDocuments({}));"
    return [pscustomobject]@{
        Measurements = "$measurements".Trim()
        Users        = "$users".Trim()
        CategoryRows = "$categoryRows".Trim()
        StatCount    = "$statCount".Trim()
        StatDocs     = "$statDocs".Trim()
    }
}

foreach ($name in @("mysql", "mongo", "analytics")) {
    if (-not (Get-Cid $name)) { throw "$name is not running. Start the stack first." }
}

Say "# Persistence test"
Say ""
Say "Command under test: ``docker compose rm -sf mysql mongo`` then ``docker compose up -d mysql mongo``."
Say "Volumes ``mysql_data`` and ``mongo_data`` are not removed."
Say ""

$insert = @"
INSERT INTO measurements (user, category, value) VALUES
('persist-script', '$Category', 10),
('persist-script', '$Category', 20),
('persist-script', '$Category', 30),
('persist-script', '$Category', 40);
"@
Invoke-Mysql $insert | Out-Null
$sqlCount = Invoke-Mysql "SELECT COUNT(*) FROM measurements WHERE category='$Category';"
Say ("Inserted 4 rows into category $Category. SQL count for that category is now $sqlCount.")
Say "Waiting up to 90s for analytics to upsert the matching stats document."

$matched = $false
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    $statCount = Invoke-Mongo "const d = db.stats.findOne({category: '$Category'}); print(d ? d.count : 'missing');"
    $statCount = "$statCount".Trim()
    if ($statCount -eq "$sqlCount".Trim()) { $matched = $true; break }
    Start-Sleep -Seconds 3
} while ($sw.Elapsed.TotalSeconds -lt 90)

if (-not $matched) {
    throw "Mongo stats count for $Category was '$statCount', SQL count was $sqlCount. Containers were not removed."
}
Say ("Stats document matched SQL after {0}s (count {1})." -f [int][math]::Ceiling($sw.Elapsed.TotalSeconds), $sqlCount)

$before = Get-Counts
Say ""
Say "Removing mysql and mongo containers."
& docker compose rm -sf mysql mongo
if ($LASTEXITCODE -ne 0) { throw "docker compose rm failed" }

Say "Recreating mysql and mongo."
$recreate = [Diagnostics.Stopwatch]::StartNew()
& docker compose up -d mysql mongo
if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
$healthy = Wait-Healthy @("mysql", "mongo") 180
$recreate.Stop()
if ($healthy -lt 0) { throw "mysql and mongo did not become healthy within 180s" }
Say ("Both databases reported healthy {0}s after recreate." -f $healthy)

$after = Get-Counts
Say ""
Say "### Persistence summary"
Say ""
Say "| Count | Before rm | After recreate | Match |"
Say "|---|---:|---:|---|"
foreach ($pair in @(
        @("MySQL measurements", $before.Measurements, $after.Measurements),
        @("MySQL users", $before.Users, $after.Users),
        @("MySQL rows in $Category", $before.CategoryRows, $after.CategoryRows),
        @("Mongo stats count for $Category", $before.StatCount, $after.StatCount),
        @("Mongo stats documents", $before.StatDocs, $after.StatDocs)
    )) {
    $match = if ($pair[1] -eq $pair[2]) { "yes" } else { "NO" }
    Say ("| {0} | {1} | {2} | {3} |" -f $pair[0], $pair[1], $pair[2], $match)
}
Say ""
Say ("Wall clock for recreate plus health: {0}s." -f [int][math]::Ceiling($recreate.Elapsed.TotalSeconds))
$passed = $before.Measurements -eq $after.Measurements -and $before.Users -eq $after.Users -and $before.CategoryRows -eq $after.CategoryRows -and $before.StatCount -eq $after.StatCount -and $before.StatDocs -eq $after.StatDocs
if ($passed) { Say "Result: no data loss." } else { Say "Result: a count changed. Do not treat this run as a pass." }

$runDir = Join-Path $Root "docs\evidence\runs"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$outFile = Join-Path $runDir ("persistence-{0}.md" -f (Get-Date).ToString("yyyyMMdd-HHmmss"))
$Report -join "`r`n" | Set-Content -Encoding utf8 $outFile
Write-Host ""
Write-Host "Wrote $outFile"
if (-not $passed) { exit 1 }
