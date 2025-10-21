#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Locate the API file that implements /schema/cards"
API_FILE="$(grep -RIl --include='*.py' -E 'def\s+schema_cards|/schema/cards' . | head -n1 || true)"
if [[ -z "${API_FILE:-}" ]]; then
  echo "✘ Could not find the /schema/cards implementation. Checked recursively for 'schema_cards'."
  exit 1
fi
echo "   found: $API_FILE"

echo ">> Patch $API_FILE to serialize datetimes when caching schema cards"
python3 - <<'PY' "$API_FILE"
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# Ensure we have an import json at top; if not, insert
if "import json" not in s:
    s = s.replace("\nfrom fastapi", "\nimport json\nfrom fastapi", 1)

# 1) Inject a small JSON default encoder after the first 'import json'
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

# 2) In schema_cards caching INSERT, add default=_jd on columns_json and samples_json
# Handle common shapes seen in your logs
s = s.replace(
    'json.dumps(t.get("columns",[]))',
    'json.dumps(t.get("columns",[]), default=_jd)'
)
s = s.replace(
    'json.dumps(t.get("samples",{}))',
    'json.dumps(t.get("samples",{}), default=_jd)'
)

# Also be defensive: any remaining json.dumps(…columns…) / json.dumps(…samples…)
s = re.sub(r'json\.dumps\(([^)]*columns[^)]*)\)',
           r'json.dumps(\1, default=_jd)', s)
s = re.sub(r'json\.dumps\(([^)]*samples[^)]*)\)',
           r'json.dumps(\1, default=_jd)', s)

p.write_text(s)
print(f"patched: {p}")
PY

echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API"
for i in {1..60}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [[ $i -eq 60 ]] && { echo "✘ API not responding"; docker compose logs --tail 150 api; exit 1; }
done

echo ">> Ensure/obtain pg-local connection id"
resp=$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | jq -r '.id // empty'); echo "conn_id=$conn_id"
[[ -n "$conn_id" ]]

echo ">> GET /schema/cards (should be 200 application/json)"
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
head -n 40 "$body" | jq . 2>/dev/null || sed -n '1,80p' "$body"

if [[ "$code" != "200" || "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards not OK. Last API logs:"
  docker compose logs --tail 200 api
  exit 1
fi

echo ">> Quick preview sanity"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ Datetime serialization fixed; schema cards healthy."
