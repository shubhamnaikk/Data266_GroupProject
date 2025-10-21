#!/usr/bin/env bash
set -euo pipefail

DF="services/ingester/Dockerfile"
API="http://localhost:8000"

[[ -f "$DF" ]] || { echo "Dockerfile not found at $DF"; exit 1; }

echo ">> Backup Dockerfile (once)"
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

echo ">> Remove any empty 'RUN pip install --no-cache-dir' lines"
# macOS/BSD sed
sed -i '' -E '/^[[:space:]]*RUN[[:space:]]+pip[[:space:]]+install[[:space:]]+--no-cache-dir[[:space:]]*$/d' "$DF"

echo ">> Rebuild API image (no cache) and restart"
docker compose build --no-cache api
docker compose up -d api

echo ">> Wait for /openapi.json to be ready"
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  if [[ "$code" == "200" ]]; then
    echo "✔ API is up"
    exit 0
  fi
  sleep 0.5
done

echo "✘ API not responding; last logs:"
docker compose logs --tail 200 api
exit 1
