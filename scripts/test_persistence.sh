#!/usr/bin/env bash
# Same evidence as test_persistence.ps1. Does not pass -v to docker compose rm.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CATEGORY="persist-check"
REPORT="$(mktemp)"
say() { printf '%s\n' "$1" | tee -a "$REPORT"; }

mysql_q() {
  docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N --batch "$MYSQL_DATABASE" 2>/dev/null' <<<"$1"
}

mongo_q() {
  docker compose exec -T mongo mongosh --quiet analytics_db --eval "$1"
}

cid() { docker compose ps -aq "$1" | head -n 1; }

for name in mysql mongo analytics; do
  [[ -n "$(cid "$name")" ]] || { echo "$name is not running." >&2; exit 1; }
done

say "# Persistence test"
say ""
say "Command under test: \`docker compose rm -sf mysql mongo\` then \`docker compose up -d mysql mongo\`."
say ""

mysql_q "INSERT INTO measurements (user, category, value) VALUES
('persist-script', '$CATEGORY', 10),
('persist-script', '$CATEGORY', 20),
('persist-script', '$CATEGORY', 30),
('persist-script', '$CATEGORY', 40);" >/dev/null

sql_count="$(mysql_q "SELECT COUNT(*) FROM measurements WHERE category='$CATEGORY';" | tr -d '[:space:]')"
say "Inserted 4 rows. SQL count for $CATEGORY is $sql_count."
say "Waiting up to 90s for the stats document."

matched=0
start="$(date +%s)"
stat_count=""
while (( $(date +%s) - start < 90 )); do
  stat_count="$(mongo_q "const d = db.getCollection('stats').findOne({category: '$CATEGORY'}); print(d ? d.count : 'missing');" | tr -d '[:space:]')"
  if [[ "$stat_count" == "$sql_count" ]]; then
    matched=1
    break
  fi
  sleep 3
done
if [[ "$matched" -ne 1 ]]; then
  echo "Mongo count '$stat_count' did not match SQL '$sql_count'. Containers were not removed." >&2
  exit 1
fi
say "Stats document matched after $(( $(date +%s) - start ))s (count $sql_count)."

measurements="$(mysql_q "SELECT COUNT(*) FROM measurements;" | tr -d '[:space:]')"
users="$(mysql_q "SELECT COUNT(*) FROM users;" | tr -d '[:space:]')"
category_rows="$sql_count"
stat_docs="$(mongo_q "print(db.getCollection('stats').countDocuments({}));" | tr -d '[:space:]')"

say ""
say "Removing mysql and mongo containers."
docker compose rm -sf mysql mongo
say "Recreating mysql and mongo."
wall="$(date +%s)"
docker compose up -d mysql mongo

start="$(date +%s)"
while true; do
  ok=1
  for name in mysql mongo; do
    id="$(cid "$name")"
    [[ -n "$id" ]] || ok=0
    status="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo missing)"
    [[ "$status" == running && "$health" == healthy ]] || ok=0
  done
  if [[ "$ok" -eq 1 ]]; then
    break
  fi
  if (( $(date +%s) - start >= 180 )); then
    echo "Databases did not become healthy." >&2
    exit 1
  fi
  sleep 2
done
say "Both databases reported healthy $(( $(date +%s) - start ))s after recreate."

a_measurements="$(mysql_q "SELECT COUNT(*) FROM measurements;" | tr -d '[:space:]')"
a_users="$(mysql_q "SELECT COUNT(*) FROM users;" | tr -d '[:space:]')"
a_category="$(mysql_q "SELECT COUNT(*) FROM measurements WHERE category='$CATEGORY';" | tr -d '[:space:]')"
a_stat="$(mongo_q "const d = db.getCollection('stats').findOne({category: '$CATEGORY'}); print(d ? d.count : 'missing');" | tr -d '[:space:]')"
a_docs="$(mongo_q "print(db.getCollection('stats').countDocuments({}));" | tr -d '[:space:]')"

row() {
  local label="$1" before="$2" after="$3" match="NO"
  [[ "$before" == "$after" ]] && match="yes"
  say "| $label | $before | $after | $match |"
}

say ""
say "### Persistence summary"
say ""
say "| Count | Before rm | After recreate | Match |"
say "|---|---:|---:|---|"
row "MySQL measurements" "$measurements" "$a_measurements"
row "MySQL users" "$users" "$a_users"
row "MySQL rows in $CATEGORY" "$category_rows" "$a_category"
row "Mongo stats count for $CATEGORY" "$stat_count" "$a_stat"
row "Mongo stats documents" "$stat_docs" "$a_docs"
say ""
say "Wall clock for recreate plus health: $(( $(date +%s) - wall ))s."

mkdir -p "$ROOT/docs/evidence/runs"
out="$ROOT/docs/evidence/runs/persistence-$(date '+%Y%m%d-%H%M%S').md"
cp "$REPORT" "$out"
echo "Wrote $out"
rm -f "$REPORT"

if [[ "$measurements" == "$a_measurements" && "$users" == "$a_users" && "$category_rows" == "$a_category" && "$stat_count" == "$a_stat" && "$stat_docs" == "$a_docs" ]]; then
  echo "Result: no data loss."
else
  echo "Result: a count changed." >&2
  exit 1
fi
