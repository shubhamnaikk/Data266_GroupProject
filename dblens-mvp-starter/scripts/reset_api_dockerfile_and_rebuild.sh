#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8000}"
DF="services/ingester/Dockerfile"

[[ -f docker-compose.yml ]] || { echo "Run from repo root"; exit 1; }
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

echo ">> Backup Dockerfile (once)"
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

echo ">> Writing a clean, known-good Dockerfile for the API image"
cat > "$DF" <<'DOCKERFILE'
FROM python:3.11-slim

# OS deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    libmagic1 jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Core + API + connectors (single pip line)
RUN pip install --no-cache-dir \
    fastapi==0.112.2 \
    uvicorn[standard]==0.30.6 \
    psycopg[binary]==3.2.1 \
    pandas==2.2.2 \
    pyarrow==16.1.0 \
    requests==2.32.3 \
    python-magic==0.4.27 \
    pymysql==1.1.0 \
    snowflake-connector-python==3.10.0 \
    sqlglot==25.6.0

WORKDIR /app
COPY . /app

# Default: start API with reload so edits show up
CMD ["uvicorn","api:app","--host","0.0.0.0","--port","8000","--reload"]
DOCKERFILE

echo ">> Rebuild API image (no cache) and restart"
docker compose build --no-cache api
docker compose up -d api

echo ">> Wait for /openapi.json"
for i in {1..60}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API_URL/openapi.json" || true)
  if [[ "$code" == "200" ]]; then
    echo "✔ API is up"
    break
  fi
  sleep 0.5
  [[ $i -eq 60 ]] && { echo "✘ API not responding; last logs:"; docker compose logs --tail 200 api; exit 1; }
done

echo ">> Verify connector deps inside the container"
docker compose exec -T api python - <<'PY'
import importlib, sys
mods = ["pymysql","snowflake.connector","sqlglot"]
bad = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        bad.append((m, str(e)))
if bad:
    print("Missing modules:", bad); sys.exit(1)
print("deps_ok")
PY

echo ">> Quick ping:"
curl -s "$API_URL/openapi.json" | head -c 200; echo
echo "✔ Reset complete"
