#!/usr/bin/env bash
# Builds the C3 baseline and optimized images and prints size and build time.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
cache=(--no-cache)
if [[ "${1:-}" == "--use-cache" ]]; then
  cache=()
fi

rows="$(mktemp)"
measure() {
  local label="$1" file="$2" context="$3" tag="$4"
  local start bytes seconds
  echo ""
  echo "Building $label ($file)"
  start="$(date +%s)"
  docker build "${cache[@]}" -f "$file" -t "$tag" "$context"
  bytes="$(docker image inspect "$tag" --format '{{.Size}}')"
  seconds="$(( $(date +%s) - start ))"
  awk -v label="$label" -v file="$file" -v size="$bytes" -v seconds="$seconds" \
    'BEGIN { printf "| %s | `%s` | %.1f | %s |\n", label, file, size/1048576, seconds }' >> "$rows"
}

measure "analytics baseline" analytics/Dockerfile.baseline analytics cit3495-analytics:baseline
measure "analytics optimized" analytics/Dockerfile analytics cit3495-analytics:optimized
measure "showresults baseline" showresults/Dockerfile.baseline showresults cit3495-showresults:baseline
measure "showresults optimized" showresults/Dockerfile showresults cit3495-showresults:optimized

echo ""
echo "| Image | Dockerfile | Size (MB) | Build (s) |"
echo "|---|---|---:|---:|"
cat "$rows"
rm -f "$rows"
echo ""
echo "Copy this table into docs/evidence/C3-image-optimization.md."
echo "These tags are not the images Compose runs."
