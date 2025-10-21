#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Patch api.py to serialize datetimes in /schema/cards cache writes"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("api.py")
s = p.read_text()

# 1) Ensure a json default helper exists (after 'import json')
if "def _jd(" not in s:
    s = re.sub(
        r"(\nimport\s+json[^\n]*\n)",
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

# 2) In the /schema/cards INSERT, change json.dumps(...) to include default=_jd
# (columns_json, samples_json) both need the default
s = s.replace(
    'json.dumps(t.get("columns",[]))',
    'json.dumps(t.get("columns",[]), default=_jd)'
)
s = s.replace(
    'json.dumps(t.get("samples",{}))',
    'json.dumps(t.get("samples",{}), default=_jd)'
)

p.write_text(s)
print("patched: api.py")
PY

echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API to be ready"
for i in {1..60}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [[ $i -eq 60 ]] && { echo "✘ API not responding"; docker compose logs --tail 150 api; exit 1; }
done

echo ">> Create/ensure pg-local connection"
resp=$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | jq -r '.id // empty'); echo "conn_id=$conn_id"
[[ -n "$conn_id" ]]

echo ">> GET /schema/cards (should be 200 application/json now)"
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
head -n 40 "$body" | jq . 2>/dev/null || sed -n '1,80p' "$body"

if [[ "$code" != "200" || "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards not OK. Last API logs:"
  docker compose logs --tail 150 api
  exit 1
fi

echo ">> Quick preview & validate sanity"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

curl -sS "$API/validate" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select * from airtravel limit 3\"}" | jq . || true

echo "✔ Datetime serialization fixed and schema cards endpoint healthy."
