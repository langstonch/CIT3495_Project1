#!/usr/bin/env bash
# Same evidence as test_failure.ps1. Run from Git Bash or Linux with the stack up.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ENTER="http://localhost:3001"
SHOW="http://localhost:3002"
REPORT="$(mktemp)"
restore=""

say() { printf '%s\n' "$1" | tee -a "$REPORT"; }

env_get() {
  grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- | tr -d '\r'
}

cid() { docker compose ps -aq "$1" | head -n 1; }

state() {
  local id status health restarts
  id="$(cid "$1")"
  if [[ -z "$id" ]]; then
    printf 'missing missing -1\n'
    return
  fi
  status="$(docker inspect -f '{{.State.Status}}' "$id")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$id")"
  printf '%s %s %s\n' "$status" "$health" "$restarts"
}

wait_healthy() {
  local timeout="$1"; shift
  local start now ready name st
  start="$(date +%s)"
  while true; do
    ready=1
    for name in "$@"; do
      st="$(state "$name")"
      [[ "$st" == running\ healthy\ * ]] || ready=0
    done
    if [[ "$ready" -eq 1 ]]; then
      now="$(date +%s)"
      echo $((now - start))
      return
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      echo -1
      return
    fi
    sleep 2
  done
}

hint_of() {
  local body="$1"
  if grep -q "Database unavailable" <<<"$body"; then echo "database unavailable"
  elif grep -q "Auth unavailable" <<<"$body"; then echo "auth unavailable"
  elif grep -q "Please log in" <<<"$body"; then echo "please log in"
  elif grep -q "Saved" <<<"$body"; then echo "saved"
  elif grep -q "Enter data" <<<"$body"; then echo "enter form"
  elif grep -q "Results" <<<"$body"; then echo "results page"
  else echo "other"
  fi
}

http_code() {
  local method="$1" url="$2" cookie="$3"
  shift 3
  local body code hint args=()
  body="$(mktemp)"
  args=(-sS -m 8 --max-redirs 0 -o "$body" -w "%{http_code}" -X "$method")
  if [[ -n "$cookie" ]]; then
    args+=(-c "$cookie")
    [[ -f "$cookie" ]] && args+=(-b "$cookie")
  fi
  while [[ $# -gt 0 ]]; do
    args+=(--data-urlencode "$1")
    shift
  done
  code="$(curl "${args[@]}" "$url" || true)"
  hint="$(hint_of "$(cat "$body")")"
  rm -f "$body"
  printf '%s %s\n' "${code:-000}" "$hint"
}

cleanup() {
  local name
  for name in $restore; do
    echo "Restoring $name"
    docker compose start "$name" >/dev/null || true
  done
  rm -f "$ENTER_JAR" "$SHOW_JAR" "$REPORT"
}
ENTER_JAR="${TMPDIR:-/tmp}/cit3495-enter-cookies.txt"
SHOW_JAR="${TMPDIR:-/tmp}/cit3495-show-cookies.txt"
trap cleanup EXIT
rm -f "$ENTER_JAR" "$SHOW_JAR"

for name in mysql mongo auth enterdata analytics showresults; do
  st="$(state "$name")"
  [[ "$st" == running\ * ]] || { echo "$name is not running. Start the stack first." >&2; exit 1; }
done

USER_NAME="$(env_get ADMIN_USER)"
PASS="$(env_get ADMIN_PASSWORD)"

say "# Failure tests"
say ""
say "Started: $(date '+%Y-%m-%d %H:%M:%S')"
say ""
say "## Test 1 - stop MySQL"
say ""
say "Command: \`docker compose stop mysql\` then \`docker compose start mysql\`."
say "Enter Data /health does not read MySQL. Analytics can stay healthy while logging job_error because the heartbeat still updates."
say ""

read -r code hint < <(http_code POST "$ENTER/login" "$ENTER_JAR" "username=$USER_NAME" "password=$PASS")
say "Login before outage: HTTP $code ($hint). Expected 303."
read -r code hint < <(http_code POST "$ENTER/data" "$ENTER_JAR" "category=failure-mysql" "value=7")
before="$code $hint"
say "Insert before outage: HTTP $before. Expected 200 saved."

since="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say ""
say "Stopping MySQL."
docker compose stop mysql
restore="mysql"
read -r code hint < <(http_code POST "$ENTER/data" "$ENTER_JAR" "category=failure-mysql" "value=8")
down="$code $hint"
say "Insert while MySQL is stopped: HTTP $down. Expected 503 database unavailable."
say "enterdata during outage: $(state enterdata)"

say "Waiting up to 80s for an analytics job_error log line."
error_seen="not seen"
start="$(date +%s)"
while true; do
  if docker compose logs --timestamps --since "$since" analytics 2>&1 | grep -q '"event": "job_error"'; then
    error_seen="seen after $(( $(date +%s) - start ))s"
    docker compose logs --timestamps --since "$since" analytics 2>&1 | grep '"event": "job_error"' | tail -n 4 | sed 's/^/    /' | tee -a "$REPORT"
    break
  fi
  if (( $(date +%s) - start >= 80 )); then
    say "analytics did not log job_error within 80s."
    break
  fi
  sleep 3
done
say "analytics during outage: $(state analytics). Healthy means the heartbeat is fresh, not that the query succeeded."

say ""
say "Starting MySQL and timing recovery."
ok_since="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
wall_start="$(date +%s)"
docker compose start mysql
mysql_seconds="$(wait_healthy 180 mysql)"
auth_seconds="$(wait_healthy 120 auth)"
docs="not seen"
start="$(date +%s)"
while true; do
  if docker compose logs --timestamps --since "$ok_since" analytics 2>&1 | grep -q '"event": "docs_written"'; then
    docs="seen"
    docker compose logs --timestamps --since "$ok_since" analytics 2>&1 | grep '"event": "docs_written"' | tail -n 4 | sed 's/^/    /' | tee -a "$REPORT"
    break
  fi
  if (( $(date +%s) - start >= 90 )); then
    break
  fi
  sleep 3
done
restore=""
read -r code hint < <(http_code POST "$ENTER/data" "$ENTER_JAR" "category=failure-mysql" "value=9")
after="$code $hint"
say "Insert after MySQL is back: HTTP $after. Expected 200 saved."
say "MySQL healthy ${mysql_seconds}s after start."
say "Auth healthy ${auth_seconds}s after MySQL was healthy."
say "analytics docs_written: $docs"
say "Wall clock from start through the post-recovery insert: $(( $(date +%s) - wall_start ))s."
say ""
say "### Test 1 summary"
say ""
say "| Check | Observation |"
say "|---|---|"
say "| Insert before stop | HTTP $before |"
say "| Insert while MySQL stopped | HTTP $down |"
say "| Insert after recovery | HTTP $after |"
say "| enterdata process | $(state enterdata) |"
say "| analytics job_error | $error_seen |"
say "| MySQL healthy again | ${mysql_seconds}s |"
say "| Auth healthy again | ${auth_seconds}s after MySQL was healthy |"
say "| analytics docs_written | $docs |"
say ""

say "## Test 2 - stop Auth"
say ""
say "No cookie stays HTTP 401. Login and cookie checks return HTTP 503 while Auth is stopped."
say ""
rm -f "$ENTER_JAR" "$SHOW_JAR"
read -r up_login _ < <(http_code POST "$ENTER/login" "$ENTER_JAR" "username=$USER_NAME" "password=$PASS")
read -r up_data up_data_hint < <(http_code GET "$ENTER/data" "$ENTER_JAR")
read -r up_anon up_anon_hint < <(http_code GET "$ENTER/data" "")
read -r up_show _ < <(http_code POST "$SHOW/login" "$SHOW_JAR" "username=$USER_NAME" "password=$PASS")
read -r up_results up_results_hint < <(http_code GET "$SHOW/results" "$SHOW_JAR")
read -r up_results_anon up_results_anon_hint < <(http_code GET "$SHOW/results" "")
enter_before="$(state enterdata | awk '{print $3}')"
show_before="$(state showresults | awk '{print $3}')"

say "Stopping Auth."
docker compose stop auth
restore="auth"
sleep 2
fresh="$(mktemp)"
read -r down_login down_login_hint < <(http_code POST "$ENTER/login" "$fresh" "username=$USER_NAME" "password=$PASS")
rm -f "$fresh"
read -r down_data down_data_hint < <(http_code GET "$ENTER/data" "$ENTER_JAR")
read -r down_anon down_anon_hint < <(http_code GET "$ENTER/data" "")
read -r down_show down_show_hint < <(http_code POST "$SHOW/login" "" "username=$USER_NAME" "password=$PASS")
read -r down_results down_results_hint < <(http_code GET "$SHOW/results" "$SHOW_JAR")
read -r down_results_anon down_results_anon_hint < <(http_code GET "$SHOW/results" "")
enter_down="$(state enterdata)"
show_down="$(state showresults)"

say "Starting Auth."
docker compose start auth
auth_back="$(wait_healthy 120 auth)"
restore=""
rm -f "$ENTER_JAR" "$SHOW_JAR"
read -r back_login _ < <(http_code POST "$ENTER/login" "$ENTER_JAR" "username=$USER_NAME" "password=$PASS")
read -r back_data back_data_hint < <(http_code GET "$ENTER/data" "$ENTER_JAR")
read -r back_show _ < <(http_code POST "$SHOW/login" "$SHOW_JAR" "username=$USER_NAME" "password=$PASS")
read -r back_results back_results_hint < <(http_code GET "$SHOW/results" "$SHOW_JAR")

say ""
say "### Test 2 summary"
say ""
say "| Request | Auth up | Auth stopped | Auth restored |"
say "|---|---|---|---|"
say "| POST /login on :3001 | $up_login | $down_login $down_login_hint | $back_login |"
say "| GET /data with cookie | $up_data $up_data_hint | $down_data $down_data_hint | $back_data $back_data_hint |"
say "| GET /data with no cookie | $up_anon $up_anon_hint | $down_anon $down_anon_hint | 401 is the no-session response |"
say "| POST /login on :3002 | $up_show | $down_show $down_show_hint | $back_show |"
say "| GET /results with cookie | $up_results $up_results_hint | $down_results $down_results_hint | $back_results $back_results_hint |"
say "| GET /results with no cookie | $up_results_anon $up_results_anon_hint | $down_results_anon $down_results_anon_hint | 401 is the no-session response |"
say ""
say "| Process | Restarts before | State during outage |"
say "|---|---|---|"
say "| enterdata | $enter_before | $enter_down |"
say "| showresults | $show_before | $show_down |"
say ""
say "Auth healthy ${auth_back}s after start."
say "Finished: $(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$ROOT/docs/evidence/runs"
out="$ROOT/docs/evidence/runs/failure-$(date '+%Y%m%d-%H%M%S').md"
cp "$REPORT" "$out"
echo "Wrote $out"
trap - EXIT
rm -f "$ENTER_JAR" "$SHOW_JAR" "$REPORT"
