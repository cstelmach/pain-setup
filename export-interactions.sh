#!/usr/bin/env bash
# File attribution
# created by Christian Stelmach (chrisp.stel@gmail.com), GitHub: @cstelmach
# Usage: ./export-interactions.sh [output-directory] [workspace/docker-compose.yml]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR/interaction-exports}"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
if [[ "$(basename "$WORKSPACE")" == pain-setup-worktrees ]]; then WORKSPACE="$(dirname "$WORKSPACE")"; fi
COMPOSE_FILE="${2:-$WORKSPACE/docker-compose.yml}"
[[ -f "$COMPOSE_FILE" ]] || { echo "Compose file not found: $COMPOSE_FILE" >&2; exit 1; }
command -v docker >/dev/null
command -v zip >/dev/null
CONTAINER_ID="$(docker compose -f "$COMPOSE_FILE" ps -q pain-db)"
[[ "$CONTAINER_ID" =~ ^[a-f0-9]+$ ]] || { echo 'Expected one running pain-db container.' >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGING="$(mktemp -d "$OUTPUT_DIR/pain-interactions-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
ARCHIVE="$STAGING.zip"
echo "Exporting interaction events. If export fails, diagnostics remain in $STAGING" >&2
docker exec -i "$CONTAINER_ID" sh -c \
  'exec psql -X -q -A -t --set=ON_ERROR_STOP=1 --username="${POSTGRES_USER:?}" --dbname="${POSTGRES_DB:?}"' \
  < "$SCRIPT_DIR/export-interactions.sql" \
  > "$STAGING/interaction-events.csv" 2> "$STAGING/summary.json"
cp "$SCRIPT_DIR/interaction-data-dictionary.txt" "$STAGING/data-dictionary.txt"
# zip removes only these freshly created files after successfully adding them to the archive.
zip -q -j -m "$STAGING/archive.pending.zip" "$STAGING/interaction-events.csv" "$STAGING/summary.json" "$STAGING/data-dictionary.txt"
mv "$STAGING/archive.pending.zip" "$ARCHIVE"
rmdir "$STAGING"
echo "Export ready: $ARCHIVE"
echo 'Copy this ZIP to your USB stick. The database was not changed.'
