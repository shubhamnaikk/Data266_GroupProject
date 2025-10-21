#!/usr/bin/env bash
set -euo pipefail

DF="services/ingester/Dockerfile"
API="http://localhost:8000"

[[ -f "$DF" ]] || { echo "Dockerfile not found at $DF"; exit 1; }

echo ">> Backup Dockerfile (once)"
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

echo ">> Ensure connectors package exists"
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

echo ">> Fix any glued COPY comment (e.g., 'COPY . /app# ...')"
# BSD/macOS sed: in-place with empty extension
sed -i '' -E 's|^(COPY[[:space:]]+\.[[:space:]]+/app).*|\1|g' "$DF"

echo ">> Remove any previously injected connector lines to avoid dupes"
sed -i '' -e '/# --- connector extras (Person A pivot) ---/d' \
          -e '/pymysql==/d' \
          -e '/snowflake-connector-python==/d' \
          -e '/sqlglot==/d' "$DF"

echo ">> Insert a clean connector block before WORKDIR (or before COPY if no WORKDIR)"
workdir_line=$(grep -nE '^[[:space:]]*WORKDIR[[:space:]]+/app' "$DF" | head -n1 | cut -d: -f1 || true)
copy_line=$(grep -nE '^[[:space:]]*COPY[[:space:]]+\.[[:space:]]+/app' "$DF" | head -n1 | cut -d: -f1 || true)

block=$'# --- connector extras (Person A pivot) ---\nRUN pip install --no-cache-dir \\\n    pymysql==1.1.0 \\\n    snowflake-connector-python==3.10.0 \\\n    sqlglot==25.6.0\n'

tmp="$(mktemp)"
if [[ -n "$workdir_line" ]]; then
  awk -v n="$workdir_line" -v blk="$block" 'NR==n{print blk} {print}' "$DF" > "$tmp"
elif [[ -n "$copy_line" ]]; then
  awk -v n="$copy_line" -v blk="$block" 'NR==n{print blk} {print}' "$DF" > "$tmp"
else
  # no anchors found; append
  cat "$DF" > "$tmp"
  printf "%b" "\n$block" >> "$tmp"
fi
mv "$tmp" "$DF"

echo ">> Rebuild API image (no cache) and restart"
docker compose build --no-cache api
docker compose up -d api

echo ">> Wait for /openapi.json to be ready"
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  if [[ "$code" == "200" ]]; then
    echo "✔ API is up"
    break
  fi
  sleep 0.5
  [[ $i -eq 40 ]] && { echo "✘ API not responding; last logs:"; docker compose logs --tail 200 api; exit 1; }
done
