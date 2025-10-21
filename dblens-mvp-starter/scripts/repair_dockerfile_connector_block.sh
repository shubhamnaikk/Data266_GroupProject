#!/usr/bin/env bash
set -euo pipefail

DF="services/ingester/Dockerfile"
[[ -f "$DF" ]] || { echo "Dockerfile not found at $DF"; exit 1; }

# 1) Make a backup once
cp -n "$DF" "${DF}.bak" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path, re
p = Path("services/ingester/Dockerfile")
s = p.read_text()

# Remove any previously appended (possibly broken) connector block(s)
s = re.sub(r'(?ms)^# --- connector extras.*?^RUN pip install[^\n]*\n(?:[^\n]*\n){0,5}', '', s)

# Fix the accidental glue: "COPY . /app# --- connector extras ..."
s = s.replace('COPY . /app# --- connector extras (Person A pivot) ---', 'COPY . /app\n# --- connector extras (Person A pivot) ---')

lines = s.splitlines()

# Find anchor lines
try:
    workdir_idx = next(i for i,l in enumerate(lines) if l.strip().startswith("WORKDIR "))
except StopIteration:
    workdir_idx = None

try:
    copy_idx = next(i for i,l in enumerate(lines) if l.strip().startswith("COPY ") and "/app" in l)
except StopIteration:
    copy_idx = None

# Build the connector block we want to insert (with a leading blank line)
connector_block = [
    "",
    "# --- connector extras (Person A pivot) ---",
    "RUN pip install --no-cache-dir \\",
    "    pymysql==1.1.0 \\",
    "    snowflake-connector-python==3.10.0 \\",
    "    sqlglot==25.6.0",
]

# Insert the block just BEFORE WORKDIR if possible, else BEFORE COPY, else append
if workdir_idx is not None:
    new_lines = lines[:workdir_idx] + connector_block + lines[workdir_idx:]
elif copy_idx is not None:
    new_lines = lines[:copy_idx] + connector_block + lines[copy_idx:]
else:
    new_lines = lines + connector_block

# Ensure file ends with newline
text = "\n".join(new_lines).rstrip() + "\n"
Path("services/ingester/Dockerfile").write_text(text)
print("Dockerfile repaired: connector deps in a separate RUN block.")
PY

# 2) Ensure the connectors package is importable
mkdir -p services/ingester/connectors
touch services/ingester/connectors/__init__.py

# 3) Rebuild & restart API
echo ">> Rebuilding API (no cache) and restarting..."
docker compose build --no-cache api
docker compose up -d api

# 4) Wait for /openapi.json to be ready
API=http://localhost:8000
echo ">> Waiting for API to come up..."
ok=0
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  if [[ "$code" == "200" ]]; then ok=1; break; fi
  sleep 0.5
done
if [[ $ok -ne 1 ]]; then
  echo "✘ API not responding; last logs:"
  docker compose logs --tail 200 api
  exit 1
fi
echo "✔ API is up"
