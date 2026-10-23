# Failure evidence for the running Compose stack.
# Requires the stack up: docker compose up --build
# Restores mysql and auth before it exits.
# Continue: docker and mysql write warnings to stderr, and Windows PowerShell 5.1 turns those into terminating errors when this is Stop.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Enter = "http://localhost:3001"
$Show = "http://localhost:3002"
$Report = New-Object System.Collections.Generic.List[string]
$ToRestore = New-Object System.Collections.Generic.List[string]

function Say([string]$Line) {
    Write-Host $Line
    $Report.Add($Line) | Out-Null
}

function Read-EnvValue([string]$Key) {
    $line = Get-Content .env | Where-Object { $_ -match "^$Key=" } | Select-Object -Last 1
    if (-not $line) { throw "Missing $Key in .env" }
    return ($line -split "=", 2)[1].Trim()
}

function Get-Cid([string]$Name) {
    $id = @(& docker compose ps -aq $Name | Where-Object { $_ -and $_.ToString().Trim() })
    if ($id.Count -eq 0) { return $null }
    return $id[0].ToString().Trim()
}

function Get-State([string]$Name) {
    $id = Get-Cid $Name
    if (-not $id) { return [pscustomobject]@{ Status = "missing"; Health = "missing"; Restarts = -1 } }
    $status = (& docker inspect -f "{{.State.Status}}" $id).Trim()
    $health = (& docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $id).Trim()
    $restarts = [int](& docker inspect -f "{{.RestartCount}}" $id)
    return [pscustomobject]@{ Status = $status; Health = $health; Restarts = $restarts }
}

function Wait-Healthy([string[]]$Names, [int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $ready = $true
        foreach ($name in $Names) {
            $state = Get-State $name
            if ($state.Status -ne "running" -or $state.Health -ne "healthy") { $ready = $false }
        }
        if ($ready) { return [int][math]::Ceiling($sw.Elapsed.TotalSeconds) }
        Start-Sleep -Seconds 2
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return -1
}

function Invoke-Curl {
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Cookie,
        [hashtable]$Form
    )
    $bodyFile = New-TemporaryFile
    $argList = @("-sS", "-m", "8", "--max-redirs", "0", "-o", $bodyFile.FullName, "-w", "%{http_code}", "-X", $Method)
    if ($Cookie) {
        $argList += @("-c", $Cookie)
        if (Test-Path $Cookie) { $argList += @("-b", $Cookie) }
    }
    if ($Form) {
        foreach ($key in $Form.Keys) { $argList += @("--data-urlencode", "$key=$($Form[$key])") }
    }
    $argList += $Url
    $code = & curl.exe @argList
    $body = ""
    if (Test-Path $bodyFile) {
        $body = Get-Content -Raw $bodyFile
        Remove-Item $bodyFile -Force
    }
    if (-not $code) { $code = "000" }
    $hint = "other"
    if ($body -match "Database unavailable") { $hint = "database unavailable" }
    elseif ($body -match "Auth unavailable") { $hint = "auth unavailable" }
    elseif ($body -match "Please log in") { $hint = "please log in" }
    elseif ($body -match "Saved") { $hint = "saved" }
    elseif ($body -match "Enter data") { $hint = "enter form" }
    elseif ($body -match "Results") { $hint = "results page" }
    return [pscustomobject]@{ Code = "$code".Trim(); Hint = $hint }
}

function Wait-Log([string]$Service, [string]$Pattern, [string]$Since, [int]$TimeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $text = & docker compose logs --timestamps --since $Since $Service 2>&1 | Out-String
        $hits = @($text -split "`n" | Where-Object { $_ -match $Pattern })
        if ($hits.Count -gt 0) {
            return [pscustomobject]@{ Found = $true; Seconds = [int][math]::Ceiling($sw.Elapsed.TotalSeconds); Lines = ($hits | Select-Object -Last 4) }
        }
        Start-Sleep -Seconds 3
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return [pscustomobject]@{ Found = $false; Seconds = $TimeoutSec; Lines = @() }
}

function Show-State([string]$Label, [string[]]$Names) {
    foreach ($name in $Names) {
        $state = Get-State $name
        Say ("| {0} | {1} | {2} | {3} | {4} |" -f $Label, $name, $state.Status, $state.Health, $state.Restarts)
    }
}

try {
    foreach ($name in @("mysql", "mongo", "auth", "enterdata", "analytics", "showresults")) {
        $state = Get-State $name
        if ($state.Status -ne "running") { throw "$name is $($state.Status). Start the stack with: docker compose up --build" }
    }

    $user = Read-EnvValue "ADMIN_USER"
    $pass = Read-EnvValue "ADMIN_PASSWORD"
    $jarEnter = Join-Path $env:TEMP "cit3495-enter-cookies.txt"
    $jarShow = Join-Path $env:TEMP "cit3495-show-cookies.txt"
    Remove-Item $jarEnter, $jarShow -ErrorAction SilentlyContinue

    Say "# Failure tests"
    Say ""
    Say "Stack project directory: $Root"
    Say ("Started: {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    Say ""
    Say "## Test 1 - stop MySQL"
    Say ""
    Say "Command: ``docker compose stop mysql`` then ``docker compose start mysql``."
    Say "Enter Data ``GET /health`` does not read MySQL, so it stays healthy. The insert is the user-visible check."
    Say "Analytics keeps its heartbeat during backoff, so it can stay healthy while logging ``job_error``."
    Say ""

    $login = Invoke-Curl -Method POST -Url "$Enter/login" -Cookie $jarEnter -Form @{ username = $user; password = $pass }
    Say ("Login before outage: HTTP {0} ({1}). Expected 303." -f $login.Code, $login.Hint)
    $before = Invoke-Curl -Method POST -Url "$Enter/data" -Cookie $jarEnter -Form @{ category = "failure-mysql"; value = "7" }
    Say ("Insert before outage: HTTP {0} ({1}). Expected 200 saved." -f $before.Code, $before.Hint)

    $since = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
    Say ""
    Say "Stopping MySQL."
    & docker compose stop mysql
    if ($LASTEXITCODE -ne 0) { throw "docker compose stop mysql failed" }
    $ToRestore.Add("mysql") | Out-Null

    $down = Invoke-Curl -Method POST -Url "$Enter/data" -Cookie $jarEnter -Form @{ category = "failure-mysql"; value = "8" }
    Say ("Insert while MySQL is stopped: HTTP {0} ({1}). Expected 503 database unavailable." -f $down.Code, $down.Hint)
    $enterState = Get-State "enterdata"
    Say ("enterdata during outage: {0} / {1}, restarts {2} (process should stay running)." -f $enterState.Status, $enterState.Health, $enterState.Restarts)

    Say "Waiting up to 80s for an analytics job_error log line."
    $errorLog = Wait-Log -Service "analytics" -Pattern '"event": "job_error"' -Since $since -TimeoutSec 80
    if ($errorLog.Found) {
        Say ("analytics logged job_error {0}s after the stop." -f $errorLog.Seconds)
        foreach ($line in $errorLog.Lines) { Say ("    " + $line.Trim()) }
    } else {
        Say "analytics did not log job_error within 80s. The job may still have been inside its sleep window; extend the wait and rerun."
    }
    $analyticsState = Get-State "analytics"
    Say ("analytics during outage: {0} / {1}. Healthy here means the heartbeat file is fresh, not that the query succeeded." -f $analyticsState.Status, $analyticsState.Health)

    Say ""
    Say "Starting MySQL and timing recovery."
    $recover = [Diagnostics.Stopwatch]::StartNew()
    $okSince = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
    & docker compose start mysql
    if ($LASTEXITCODE -ne 0) { throw "docker compose start mysql failed" }
    $mysqlSeconds = Wait-Healthy @("mysql") 180
    $authSeconds = Wait-Healthy @("auth") 120
    $okLog = Wait-Log -Service "analytics" -Pattern '"event": "docs_written"' -Since $okSince -TimeoutSec 90
    $recover.Stop()
    $ToRestore.Remove("mysql") | Out-Null

    $after = Invoke-Curl -Method POST -Url "$Enter/data" -Cookie $jarEnter -Form @{ category = "failure-mysql"; value = "9" }
    Say ("Insert after MySQL is back: HTTP {0} ({1}). Expected 200 saved." -f $after.Code, $after.Hint)
    if ($mysqlSeconds -lt 0) { Say "MySQL did not become healthy within 180s." } else { Say ("MySQL healthy {0}s after start." -f $mysqlSeconds) }
    if ($authSeconds -lt 0) { Say "Auth did not become healthy within 120s after MySQL was healthy." } else { Say ("Auth healthy {0}s after MySQL was healthy (its /health reads MySQL)." -f $authSeconds) }
    if ($okLog.Found) {
        Say "analytics logged docs_written after the outage."
        foreach ($line in $okLog.Lines) { Say ("    " + $line.Trim()) }
    } else {
        Say "analytics did not log docs_written within 90s of the restart window."
    }
    Say ("Wall clock from start command through the post-recovery insert: {0}s." -f [int][math]::Ceiling($recover.Elapsed.TotalSeconds))

    Say ""
    Say "### Test 1 summary"
    Say ""
    Say "| Check | Observation |"
    Say "|---|---|"
    Say ("| Insert before stop | HTTP {0} {1} |" -f $before.Code, $before.Hint)
    Say ("| Insert while MySQL stopped | HTTP {0} {1} |" -f $down.Code, $down.Hint)
    Say ("| Insert after recovery | HTTP {0} {1} |" -f $after.Code, $after.Hint)
    Say ("| enterdata process | {0}, health {1}, restarts {2} |" -f $enterState.Status, $enterState.Health, $enterState.Restarts)
    Say ("| analytics job_error | {0} |" -f $(if ($errorLog.Found) { "seen after $($errorLog.Seconds)s" } else { "not seen" }))
    Say ("| MySQL healthy again | {0} |" -f $(if ($mysqlSeconds -lt 0) { "timed out" } else { "$mysqlSeconds s" }))
    Say ("| Auth healthy again | {0} |" -f $(if ($authSeconds -lt 0) { "timed out" } else { "$authSeconds s after MySQL was healthy" }))
    Say ("| analytics docs_written | {0} |" -f $(if ($okLog.Found) { "seen" } else { "not seen" }))
    Say ""

    Say "## Test 2 - stop Auth"
    Say ""
    Say "Command: ``docker compose stop auth`` then ``docker compose start auth``."
    Say "A request with no cookie does not call Auth, so it stays HTTP 401."
    Say "Login and cookie checks call Auth. With the container stopped those return HTTP 503 and the page says auth is unavailable. The Node processes keep running."
    Say ""

    Remove-Item $jarEnter, $jarShow -ErrorAction SilentlyContinue
    $upLoginEnter = Invoke-Curl -Method POST -Url "$Enter/login" -Cookie $jarEnter -Form @{ username = $user; password = $pass }
    $upData = Invoke-Curl -Method GET -Url "$Enter/data" -Cookie $jarEnter
    $upAnon = Invoke-Curl -Method GET -Url "$Enter/data"
    $upLoginShow = Invoke-Curl -Method POST -Url "$Show/login" -Cookie $jarShow -Form @{ username = $user; password = $pass }
    $upResults = Invoke-Curl -Method GET -Url "$Show/results" -Cookie $jarShow
    $upResultsAnon = Invoke-Curl -Method GET -Url "$Show/results"
    $enterRestarts = (Get-State "enterdata").Restarts
    $showRestarts = (Get-State "showresults").Restarts

    Say "Stopping Auth."
    & docker compose stop auth
    if ($LASTEXITCODE -ne 0) { throw "docker compose stop auth failed" }
    $ToRestore.Add("auth") | Out-Null
    Start-Sleep -Seconds 2

    $downLoginEnter = Invoke-Curl -Method POST -Url "$Enter/login" -Cookie (Join-Path $env:TEMP "cit3495-enter-nocookie.txt") -Form @{ username = $user; password = $pass }
    $downData = Invoke-Curl -Method GET -Url "$Enter/data" -Cookie $jarEnter
    $downAnon = Invoke-Curl -Method GET -Url "$Enter/data"
    $downLoginShow = Invoke-Curl -Method POST -Url "$Show/login" -Form @{ username = $user; password = $pass }
    $downResults = Invoke-Curl -Method GET -Url "$Show/results" -Cookie $jarShow
    $downResultsAnon = Invoke-Curl -Method GET -Url "$Show/results"
    $enterDown = Get-State "enterdata"
    $showDown = Get-State "showresults"

    Say "Starting Auth and timing recovery."
    $authSw = [Diagnostics.Stopwatch]::StartNew()
    & docker compose start auth
    if ($LASTEXITCODE -ne 0) { throw "docker compose start auth failed" }
    $authBack = Wait-Healthy @("auth") 120
    $authSw.Stop()
    $ToRestore.Remove("auth") | Out-Null

    Remove-Item $jarEnter, $jarShow -ErrorAction SilentlyContinue
    $backLogin = Invoke-Curl -Method POST -Url "$Enter/login" -Cookie $jarEnter -Form @{ username = $user; password = $pass }
    $backData = Invoke-Curl -Method GET -Url "$Enter/data" -Cookie $jarEnter
    $backShow = Invoke-Curl -Method POST -Url "$Show/login" -Cookie $jarShow -Form @{ username = $user; password = $pass }
    $backResults = Invoke-Curl -Method GET -Url "$Show/results" -Cookie $jarShow

    Say ""
    Say "### Test 2 summary"
    Say ""
    Say "| Request | Auth up | Auth stopped | Auth restored |"
    Say "|---|---|---|---|"
    Say ("| POST /login on :3001 | {0} | {1} {2} | {3} |" -f $upLoginEnter.Code, $downLoginEnter.Code, $downLoginEnter.Hint, $backLogin.Code)
    Say ("| GET /data with cookie | {0} {1} | {2} {3} | {4} {5} |" -f $upData.Code, $upData.Hint, $downData.Code, $downData.Hint, $backData.Code, $backData.Hint)
    Say ("| GET /data with no cookie | {0} {1} | {2} {3} | 401 is the no-session response |" -f $upAnon.Code, $upAnon.Hint, $downAnon.Code, $downAnon.Hint)
    Say ("| POST /login on :3002 | {0} | {1} {2} | {3} |" -f $upLoginShow.Code, $downLoginShow.Code, $downLoginShow.Hint, $backShow.Code)
    Say ("| GET /results with cookie | {0} {1} | {2} {3} | {4} {5} |" -f $upResults.Code, $upResults.Hint, $downResults.Code, $downResults.Hint, $backResults.Code, $backResults.Hint)
    Say ("| GET /results with no cookie | {0} {1} | {2} {3} | 401 is the no-session response |" -f $upResultsAnon.Code, $upResultsAnon.Hint, $downResultsAnon.Code, $downResultsAnon.Hint)
    Say ""
    Say "| Process | Restarts before | Status during outage | Restarts during outage |"
    Say "|---|---|---|---|"
    Say ("| enterdata | {0} | {1} / {2} | {3} |" -f $enterRestarts, $enterDown.Status, $enterDown.Health, $enterDown.Restarts)
    Say ("| showresults | {0} | {1} / {2} | {3} |" -f $showRestarts, $showDown.Status, $showDown.Health, $showDown.Restarts)
    Say ""
    if ($authBack -lt 0) { Say "Auth did not become healthy within 120s." } else { Say ("Auth healthy {0}s after start." -f $authBack) }
    Say "A restart count that does not increase, with status running, is the evidence the web apps did not crash."
    Say ""
    Say ("Finished: {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
}
finally {
    foreach ($name in $ToRestore) {
        Write-Host "Restoring $name"
        & docker compose start $name | Out-Null
    }
    Remove-Item (Join-Path $env:TEMP "cit3495-enter-cookies.txt"), (Join-Path $env:TEMP "cit3495-show-cookies.txt"), (Join-Path $env:TEMP "cit3495-enter-nocookie.txt") -ErrorAction SilentlyContinue
}

$runDir = Join-Path $Root "docs\evidence\runs"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$outFile = Join-Path $runDir ("failure-{0}.md" -f (Get-Date).ToString("yyyyMMdd-HHmmss"))
$Report -join "`r`n" | Set-Content -Encoding utf8 $outFile
Write-Host ""
Write-Host "Wrote $outFile"
