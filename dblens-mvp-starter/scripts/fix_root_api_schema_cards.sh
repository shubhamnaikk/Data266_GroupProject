#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

# 1) Find the FastAPI file actually serving /schema/cards (prefer ./api.py)
if [ -f ./api.py ]; then
  TARGET=./api.py
else
  TARGET="$(grep -RIl --include='*.py' -E 'def[[:space:]]+schema_cards|/schema/cards' . | head -n1 || true)"
fi
if [ -z "${TARGET:-}" ] || [ ! -f "$TARGET" ]; then
  echo "✘ Could not find FastAPI file implementing /schema/cards"; exit 1
fi
echo ">> Patching: $TARGET"
cp -n "$TARGET" "$TARGET.bak.$(date +%s)" || true

# 2) Patch: add _jd helper, fix dict.get misuse, ensure json.dumps(..., default=_jd)
python3 - "$TARGET" <<'PY'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()

# ensure import json exists before FastAPI import
if "import json" not in s:
    s = s.replace("\nfrom fastapi", "\nimport json\nfrom fastapi", 1)

# inject _jd helper after import json if missing
if "def _jd(" not in s:
    s = re.sub(
        r"(import\s+json[^\n]*\n)",
        r"""\1
# --- JSON default encoder for datetimes/decimals/others ---
def _jd(obj):
    try:
        import datetime, decimal
        if isinstance(obj, (datetime.datetime, datetime.date)):
            return obj.isoformat()
        if isinstance(obj, decimal.Decimal):
            return float(obj)
    except Exception:
        pass
    return str(obj)
# ----------------------------------------------------------
""",
        s, count=1
    )

# remove accidental 'default=_jd' inside dict.get(...)
s = re.sub(r't\.get\(\s*([\'"])columns\1\s*,\s*\[\]\s*,\s*default\s*=\s*_jd\s*\)', r't.get(\1columns\1, [])', s)
s = re.sub(r't\.get\(\s*([\'"])samples\1\s*,\s*\{\}\s*,\s*default\s*=\s*_jd\s*\)', r't.get(\1samples\1, {})', s)

# ensure json.dumps on columns/samples includes default=_jd
def add_def(body:str)->str:
    return body if 'default=_jd' in body else body[:-1] + ', default=_jd)'

s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\'"])columns\1\s*,\s*\[\]\s*\)\s*\)', lambda m: add_def(m.group(0)), s)
s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\'"])samples\1\s*,\s*\{\}\s*\)\s*\)', lambda m: add_def(m.group(0)), s)

# extra safety: any dumps mentioning columns/samples gets default
s = re.sub(r'json\.dumps\([^)]*columns[^)]*\)', lambda m: add_def(m.group(0)), s)
s = re.sub(r'json\.dumps\([^)]*samples[^)]*\)', lambda m: add_def(m.group(0)), s)

p.write_text(s)
print(f"patched: {p}")
PY

# 3) Rebuild & restart API
echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

# 4) Wait for API
echo ">> Wait for API"
for i in $(seq 1 60); do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [ "$code" = "200" ] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [ $i -eq 60 ] && { echo "✘ API not responding"; docker compose logs --tail 200 api; exit 1; }
done

# 5) Create/ensure pg-local connection and parse id (robustly, no jq required)
echo ">> Ensure pg-local connection"
resp="$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")"
echo "$resp"
conn_id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
[ -n "${conn_id:-}" ] || { echo "✘ could not parse conn_id"; exit 1; }
echo "conn_id=$conn_id"

# 6) GET /schema/cards (should be 200 JSON). Show first lines.
echo ">> GET /schema/cards"
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
head -n 60 "$body" || true

if [ "$code" != "200" ] || [[ "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards not OK. API log tail:"
  docker compose logs --tail 200 api
  exit 1
fi

# 7) Quick /preview sanity
echo ">> /preview sanity"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | sed -n '1,80p'

echo "✔ Fix applied and schema/cards working."
