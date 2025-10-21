#!/usr/bin/env bash
set -euo pipefail

# Files that might implement /schema/cards (root and service copies)
CANDS="api.py services/ingester/api.py services/ingester/dbtools.py"

found_any=0
ts="$(date +%s)"

for f in $CANDS; do
  [[ -f "$f" ]] || continue
  found_any=1
  cp "$f" "${f}.bak.${ts}"

  # Do the heavy edits in Python so we can handle multi-line cases safely.
  python3 - "$f" <<'PY'
import sys, re, pathlib

p = pathlib.Path(sys.argv[1])
s = p.read_text()

# ---- 1) Ensure a JSON default helper exists (idempotent)
if "def _jd(" not in s:
    helper = """
# --- json default helper for datetime/decimal/etc ---
def _jd(o):
    import datetime, decimal
    if isinstance(o, (datetime.datetime, datetime.date)):
        return o.isoformat()
    if isinstance(o, decimal.Decimal):
        return float(o)
    try:
        return str(o)
    except Exception:
        return None
"""
    # inject after imports block
    s = re.sub(r"((?:from\s+\S+\s+import\s+.*\n|import\s+\S+.*\n)+)", r"\1"+helper+"\n", s, count=1)

# ---- 2) Strip illegal keyword args from dict.get(..., default=_jd)
# Case: two positional args + keyword "default=_jd"
s = re.sub(
    r"\.get\(\s*([^,\)\n]+)\s*,\s*([^,\)\n]+)\s*,\s*default\s*=\s*_jd\s*\)",
    r".get(\1, \2)",
    s,
    flags=re.S
)
# Case: one positional arg + keyword "default=_jd"
s = re.sub(
    r"\.get\(\s*([^,\)\n]+)\s*,\s*default\s*=\s*_jd\s*\)",
    r".get(\1)",
    s,
    flags=re.S
)

# ---- 3) Make sure json.dumps(..., default=_jd) is used when dumping columns/samples
def add_default_if_missing(m):
    whole = m.group(0)
    inner = m.group(1)
    # If default already there, leave as is
    if re.search(r"default\s*=", whole):
        return whole
    return f"json.dumps({inner}, default=_jd)"

# columns payloads
s = re.sub(r"json\.dumps\(\s*([^)]*columns[^)]*)\)", add_default_if_missing, s, flags=re.S)
# samples payloads
s = re.sub(r"json\.dumps\(\s*([^)]*samples[^)]*)\)", add_default_if_missing, s, flags=re.S)

# ---- 4) Last-gasp: brutally remove any lingering ', default=_jd' that might still be inside get(...)
s = re.sub(r"(\.get\([^)]*?),\s*default\s*=\s*_jd(\s*\))", r"\1\2", s, flags=re.S)

p.write_text(s)
print(f"patched: {p}")
PY
done

if [[ "$found_any" -eq 0 ]]; then
  echo "No candidate files found (run from repo root)."
  exit 1
fi

echo ">> Rebuild API image and restart..."
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API..."
for i in $(seq 1 40); do
  if curl -fsS http://localhost:8000/openapi.json >/dev/null; then
    echo "API is up"
    break
  fi
  sleep 0.5
  if [[ "$i" -eq 40 ]]; then
    echo "✘ API not responding"
    docker compose logs --tail 200 api
    exit 1
  fi
done

echo ">> Ensure/obtain a pg-local connection id"
resp="$(curl -sS -X POST http://localhost:8000/connections \
  -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}')"
CID="$(printf "%s" "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if [[ -z "${CID:-}" ]]; then
  echo "✘ Could not parse conn_id from /connections: $resp"
  exit 1
fi
echo "conn_id=$CID"

echo ">> GET /schema/cards"
code=$(curl -sS -w '%{http_code}' -o /tmp/cards.json "http://localhost:8000/schema/cards?conn_id=${CID}")
ctype=$(curl -sS -D - -o /dev/null "http://localhost:8000/schema/cards?conn_id=${CID}" | awk -F': ' '/[Cc]ontent-[Tt]ype:/ {print $2}' | tr -d '\r')

echo "HTTP $code | content-type: ${ctype:-unknown}"
if [[ "$code" != "200" ]]; then
  echo "!! /schema/cards still failing. Last API logs:"
  docker compose logs --tail 150 api
  exit 1
fi

head -c 400 /tmp/cards.json; echo
echo "✔ /schema/cards healthy"
