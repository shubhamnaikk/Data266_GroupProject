#!/usr/bin/env bash
set -euo pipefail

# Files that may implement /schema/cards
CANDS=(services/ingester/api.py services/ingester/dbtools.py)

# 1) Sanity: make sure at least one target exists
found=0
for f in "${CANDS[@]}"; do
  if [[ -f "$f" ]]; then
    found=1
  fi
done
if [[ "$found" -eq 0 ]]; then
  echo "✘ No target files found (looked for: ${CANDS[*]}). Run this from repo root." >&2
  exit 1
fi

# 2) Patch each file
for f in "${CANDS[@]}"; do
  [[ -f "$f" ]] || continue
  cp "$f" "${f}.bak.$(date +%s)"

  python3 - "$f" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()

# Ensure _jd helper exists (idempotent)
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
    # put helper near top after imports
    s = re.sub(r"(\nfrom\s+.+?\n|import\s+.+?\n)+", lambda m: m.group(0) + helper, s, count=1)

# Remove invalid keyword-arg usage on dict.get(...)
s = re.sub(r'\.get\(\s*"columns"\s*,\s*\[\s*\]\s*,\s*default=_jd\s*\)', '.get("columns", [])', s)
s = re.sub(r"\.get\(\s*'columns'\s*,\s*\[\s*\]\s*,\s*default=_jd\s*\)", ".get('columns', [])", s)
s = re.sub(r'\.get\(\s*"samples"\s*,\s*\{\s*\}\s*,\s*default=_jd\s*\)', '.get("samples", {})', s)
s = re.sub(r"\.get\(\s*'samples'\s*,\s*\{\s*\}\s*,\s*default=_jd\s*\)", ".get('samples', {})", s)

# Make sure json.dumps(..., default=_jd) is used when writing cache rows
# Only touch the specific INSERT into schema_card_cache call(s)
def fix_dumps(m):
    inside = m.group(1)
    if "default=_jd" in inside:
        return f"json.dumps({inside})"
    return f"json.dumps({inside}, default=_jd)"

s = re.sub(r"json\.dumps\(\s*([^)]*columns[^)]*)\)", fix_dumps, s)
s = re.sub(r"json\.dumps\(\s*([^)]*samples[^)]*)\)", fix_dumps, s)

p.write_text(s)
print(f"patched: {p}")
PY

done

# 3) Rebuild API and restart
docker compose build api >/dev/null
docker compose up -d api >/dev/null

# 4) Wait for API
printf ">> Waiting for API..."
for i in {1..20}; do
  if curl -fsS http://localhost:8000/openapi.json >/dev/null; then
    echo " OK"
    break
  fi
  sleep 0.5
  if [[ "$i" -eq 20 ]]; then
    echo " ✘ API not responding"
    docker compose logs --tail 200 api
    exit 1
  fi
done

# 5) Ensure/obtain a pg-local connection (idempotent)
resp="$(curl -sS -X POST http://localhost:8000/connections \
  -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}')"
CID="$(printf "%s" "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if [[ -z "${CID:-}" ]]; then
  echo "✘ Could not parse conn_id from /connections response: $resp"
  exit 1
fi
echo "conn_id=$CID"

# 6) Smoke /schema/cards
code=$(curl -sS -w '%{http_code}' -o /tmp/cards.json "http://localhost:8000/schema/cards?conn_id=${CID}")
ctype=$(curl -sS -D - -o /dev/null "http://localhost:8000/schema/cards?conn_id=${CID}" | awk -F': ' '/[Cc]ontent-[Tt]ype:/ {print $2}' | tr -d '\r')
echo "HTTP $code | content-type: ${ctype:-unknown}"
if [[ "$code" != "200" ]]; then
  echo "!! /schema/cards not OK. Last API logs:" >&2
  docker compose logs --tail 200 api >&2
  exit 1
fi

# Show a quick glimpse
head -n 1 /tmp/cards.json && echo
echo "✔ /schema/cards is healthy."
