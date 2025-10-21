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

echo ">> Repair Dockerfile (remove broken glue, insert clean connector block)"
python3 - <<'PY'
import re
from pathlib import Path

p = Path("services/ingester/Dockerfile")
s = p.read_text()

# 1) If someone glued a comment onto COPY line, strip trailing comments
fixed_lines = []
for line in s.splitlines():
    if line.strip().startswith("COPY ") and "/app" in line:
        # keep only before '#' if present
        line = line.split("#", 1)[0].rstrip()
    fixed_lines.append(line)
s = "\n".join(fixed_lines)

# 2) Remove any previous connector block we injected
s = re.sub(
    r"(?ms)^# --- connector extras \(Person A pivot\) ---\nRUN pip install --no-cache-dir \\\n\s*.*pymysql==[^\n]*\n\s*.*snowflake-connector-python==[^\n]*\n\s*.*sqlglot==[^\n]*\n",
    "",
    s,
)

lines = s.splitlines()

# 3) Build a clean connector block
block = [
    "# --- connector extras (Person A pivot) ---",
    "RUN pip install --no-cache-dir \\",
    "    pymysql==1.1.0 \\",
    "    snowflake-connector-python==3.10.0 \\",
    "    sqlglot==25.6.0",
]

# 4) Insert block before WORKDIR if present; else before COPY; else append
def find_index(prefix):
    for i, ln in enumerate(lines):
        if ln.strip().startswith(prefix):
            return i
    return None

idx_workdir = find_index("WORKDIR ")
idx_copy    = None
for i, ln in enumerate(lines):
    if ln.strip().startswith("COPY ") and "/app" in ln:
        idx_copy = i
        break

if idx_workdir is not None:
    insert_at = idx_workdir
elif idx_copy is not None:
    insert_at = idx_copy
else:
    insert_at = len(lines)

new_lines = lines[:insert_at] + [""] + block + [""] + lines[insert_at:]
p.write_text("\n".join(new_lines).rstrip() + "\n")
print("Dockerfile repaired.")
PY

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
