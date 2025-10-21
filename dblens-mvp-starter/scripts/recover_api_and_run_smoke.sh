#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 1) Ensure connectors package is importable
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

# 2) Rebuild & restart API
echo ">> Rebuilding API image..."
docker compose up -d --build api

# 3) Wait for /openapi.json
API=http://localhost:8000
echo ">> Waiting for API..."
ok=0
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  if [[ "$code" == "200" ]]; then ok=1; break; fi
  sleep 0.5
done
if [[ $ok -ne 1 ]]; then
  echo "✘ API not responding, showing last logs:"
  docker compose logs --tail 200 api
  exit 1
fi
echo "✔ API is up"

# 4) Run the smoke tests
if [[ -x scripts/test_connectors_smoke.sh ]]; then
  echo ">> Running connector smoke tests..."
  bash scripts/test_connectors_smoke.sh
else
  echo "△ scripts/test_connectors_smoke.sh not found or not executable."
  echo "   You can run it manually after making it executable:"
  echo "   chmod +x scripts/test_connectors_smoke.sh && bash scripts/test_connectors_smoke.sh"
fi
