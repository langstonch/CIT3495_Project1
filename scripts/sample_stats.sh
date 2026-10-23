#!/usr/bin/env bash
# Samples docker stats for the load-test window. Arg 1 is seconds (default 40).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
seconds="${1:-40}"
mkdir -p "$ROOT/docs/evidence/runs"
out="$ROOT/docs/evidence/runs/docker-stats-$(date '+%Y%m%d-%H%M%S').csv"
echo "timestamp,name,cpu,mem" > "$out"
end=$(( $(date +%s) + seconds ))
while (( $(date +%s) < end )); do
  stamp="$(date '+%Y-%m-%dT%H:%M:%S')"
  docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "$stamp,$line" >> "$out"
  done
  sleep 2
done
echo "Wrote $out"
