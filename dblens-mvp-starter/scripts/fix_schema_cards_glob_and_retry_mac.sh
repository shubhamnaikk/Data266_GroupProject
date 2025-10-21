#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Locate all API files implementing /schema/cards"
FILES="$(grep -RIl --include='*.py' -E 'def[[:space:]]+schema_cards|/schema/cards' . || true)"
if [ -z "${FILES:-}" ]; then
  echo "✘ Could not find any schema_cards endpoint"; exit 1
fi
echo "$FILES" | sed 's/^/   found: /'

echo ">> Patch all targets: add _jd helper, fix json.dumps + dict.get"
printf "%s\n" $FILES | python3 - <<'PY'
import re, sys
from pathlib import Path

files=[l.strip() for l in sys.stdin if l.strip()]
for f in files:
    p=Path(f); s=p.read_text()

    # ensure import json (before first FastAPI import if needed)
    if "import json" not in s:
        s = s.replace("\nfrom fastapi", "\nimport json\nfrom fastapi", 1)

    # inject _jd helper after first 'import json' if missing
    if "def _jd(" not in s:
        s = re.sub(r"(import\s+json[^\n]*\n)",
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
""", s, count=1)

    # remove accidental 'default=_jd' inside dict.get(...)
    s = re.sub(r't\.get\(\s*([\"\'])columns\1\s*,\s*\[\]\s*,\s*default\s*=\s*_jd\s*\)',
               r't.get(\1columns\1, [])', s)
    s = re.sub(r't\.get\(\s*([\"\'])samples\1\s*,\s*\{\}\s*,\s*default\s*=\s*_jd\s*\)',
               r't.get(\1samples\1, {})', s)

    # ensure json.dumps on columns/samples includes default=_jd
    s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\"\'])columns\1\s*,\s*\[\]\s*\)\s*\)',
               r'json.dumps(t.get(\1columns\1, []), default=_jd)', s)
    s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\"\'])samples\1\s*,\s*\{\}\s*\)\s*\)',
               r'json.dumps(t.get(\1samples\1, {}), default=_jd)', s)

    # safety net: if any dumps with columns/samples lacks default, add it
    def add_def(m):
        body=m.group(0)
        return body if 'default=_jd' in body else body[:-1] + ', default=_jd)'
    s = re.sub(r'json\.dumps\([^)]*columns[^)]*\)', add_def, s)
    s = re.sub(r'json\.dumps\([^)]*samples[^)]*\)', add_def, s)

    p.write_text(s)
    print(f"patched: {p}")
PY

echo ">> Rebuild & restart API"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API"
for i in $(seq 1 60); do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [ "$code" = "200" ] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [ $i -eq 60 ] && { echo "✘ API not responding"; docker compose logs --tail 200 api; exit 1; }
done

echo ">> Ensure pg-local connection"
resp=$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | /usr/bin/python3 - <<'PY2'
import sys, json
try:
    print(json.load(sys.stdin).get("id",""))
except Exception: print("")
PY2
)
[ -n "$conn_id" ] || { echo "✘ no conn_id"; exit 1; }
echo "conn_id=$conn_id"

echo ">> GET /schema/cards (expect 200 application/json)"
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

echo ">> /preview sanity"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | sed -n '1,80p'

echo "✔ schema/cards fixed across files."
