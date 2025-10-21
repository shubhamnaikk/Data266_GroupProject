#!/usr/bin/env bash
set -euo pipefail

DF="services/ingester/Dockerfile"

echo ">> Ensure connectors package is importable"
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

echo ">> Back up Dockerfile (once)"
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

# Append a dedicated RUN line for connector deps if missing
if ! grep -q 'snowflake-connector-python' "$DF"; then
  echo ">> Appending connector deps to Dockerfile"
  cat >> "$DF" <<'DOCK'
# --- connector extras (Person A pivot) ---
RUN pip install --no-cache-dir \
    pymysql==1.1.0 \
    snowflake-connector-python==3.10.0 \
    sqlglot==25.6.0
DOCK
else
  echo ">> Connector deps already present in Dockerfile"
fi

echo ">> Rebuild API image (no cache) and restart"
docker compose build --no-cache api
docker compose up -d api

echo ">> Wait for /openapi.json to be ready"
API=http://localhost:8000
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  if [[ "$code" == "200" ]]; then
    echo "✔ API is up"
    break
  fi
  sleep 0.5
  [[ $i -eq 40 ]] && { echo "✘ API not responding, dumping logs"; docker compose logs --tail 200 api; exit 1; }
done

echo ">> Quick ping:"
curl -s "$API/openapi.json" | head -c 200; echo
