#!/usr/bin/env bash
set -euo pipefail

TARGETS=("services/ingester/api.py" "services/ingester/dbtools.py")
patched_any=0

for f in "${TARGETS[@]}"; do
  [[ -f "$f" ]] || continue
  cp "$f" "${f}.bak.$(date +%s)"

  python3 - "$f" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()

# Ensure a JSON default helper exists (idempotent)
if "_jd(" not in s:
    helper = """
# --- json default helper for datetime/decimal/etc ---
def _jd(o):
    import datetime, decimal
    if isinstance(o, (datetime.datetime, datetime.date)):
        return o.isoformat()
    if isinstance(o, decimal.Decimal):
        return float(o)
    return str(o)
"""
    # Insert helper after the first block of imports if possible
    s = re.sub(r"((?:from\s+\S+\s+import\s+.*\n|import\s+\S+.*\n)+)",
               r"\1" + helper + "\n", s, count=1)

# Strip invalid keyword arg on dict.get(..., default=_jd)
# columns
s = re.sub(
    r"""\.get\(\s*(['"]columns['"])\s*,\s*([^,\)]*)\s*,\s*default\s*=\s*_jd\s*\)""",
    r".get(\1, \2)", s)
# samples
s = re.sub(
    r"""\.get\(\s*(['"]samples['"])\s*,\s*([^,\)]*)\s*,\s*default\s*=\s*_jd\s*\)""",
    r".get(\1, \2)", s)

# Ensure json.dumps(..., default=_jd) for columns & samples payloads going into cache
def ensure_default(m):
    inside = m.group(1)
    if "default=_jd" in inside:
        return f"json.dumps({inside})"
    return f"json.dumps({inside}, default=_jd)"

s = re.sub(r"json\.dumps\(\s*([^)]*columns[^)]*)\)", ensure_default, s)
s = re.sub(r"json\.dumps\(\s*([^)]*samples[^)]*)\)", ensure_default, s)

p.write_text(s)
print(f"patched: {p}")
PY

  patched_any=1
done

if [[ "$patched_any" -eq 0 ]]; then
  echo "No target files found to patch. Run from repo root." >&2
  exit 1
fi

# Rebuild + restart API
docker compose build api >/dev/null
docker compose up -d api >/dev/null

# Wait for API
echo ">> Waiting for API..."
for i in {1..30}; do
  if curl -fsS http://localhost:8000/openapi.json >/dev/null; then
    echo "API is up"
    break
  fi
  sleep 0.5
  if [[ "$i" -eq 30 ]]; then
    echo "✘ API not responding"
    docker compose logs --tail 200 api
    exit 1
  fi
done

# Ensure/obtain a pg-local connection
resp="$(curl -sS -X POST http://localhost:8000/connections \
  -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}')"
CID="$(printf "%s" "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if [[ -z "${CID:-}" ]]; then
  echo "✘ Could not parse conn_id from /connections response: $resp"
  exit 1
fi
echo "conn_id=${CID}"

# Hit /schema/cards
code=$(curl -sS -w '%{http_code}' -o /tmp/cards.json "http://localhost:8000/schema/cards?conn_id=${CID}")
ctype=$(curl -sS -D - -o /dev/null "http://localhost:8000/schema/cards?conn_id=${CID}" | awk -F': ' '/[Cc]ontent-[Tt]ype:/ {print $2}' | tr -d '\r')
echo "HTTP $code | content-type: ${ctype:-unknown}"

if [[ "$code" != "200" ]]; then
  echo "!! /schema/cards not OK. Last API logs:" >&2
  docker compose logs --tail 200 api >&2
  exit 1
fi

head -c 300 /tmp/cards.json; echo
echo "✔ /schema/cards healthy"
