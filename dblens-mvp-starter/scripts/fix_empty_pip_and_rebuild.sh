#!/usr/bin/env bash
set -euo pipefail

DF="services/ingester/Dockerfile"
API="http://localhost:8000"

[[ -f "$DF" ]] || { echo "Dockerfile not found at $DF"; exit 1; }

echo ">> Backup Dockerfile (once)"
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

echo ">> Remove any EMPTY 'RUN pip install --no-cache-dir' lines (with or without trailing backslash)"
python3 - <<'PY'
import re
from pathlib import Path

p = Path("services/ingester/Dockerfile")
s = p.read_text()

# Drop any lines that are just: RUN pip install --no-cache-dir   (optionally with trailing '\')
pattern = re.compile(r'^\s*RUN\s+pip\s+install\s+--no-cache-dir\s*(\\\s*)?$', re.IGNORECASE | re.MULTILINE)
s2 = re.sub(pattern, '', s)

# Also collapse accidental multiple blank lines
s2 = re.sub(r'\n{3,}', '\n\n', s2).strip() + "\n"

if s != s2:
    p.write_text(s2)
    print("Patched Dockerfile: removed empty pip install line(s).")
else:
    print("No empty pip install lines found; nothing to patch.")
PY

echo ">> Ensure connectors package exists"
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

echo ">> Show pip install lines after patch (sanity):"
grep -nEi 'RUN[[:space:]]+pip[[:space:]]+install' "$DF" || true

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
