#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Locate API file implementing /schema/cards"
API_FILE="$(grep -RIl --include='*.py' -E 'def\s+schema_cards|/schema/cards' . | head -n1 || true)"
[[ -n "${API_FILE:-}" ]] || { echo "✘ Could not find schema_cards endpoint"; exit 1; }
echo "   found: $API_FILE"

echo ">> Fix dict.get misuse (remove 'default=_jd' inside t.get(...)) and ensure json.dumps(..., default=_jd)"
python3 - "$API_FILE" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

# 1) Remove accidental 'default=_jd' added inside dict.get(...) for columns/samples
s = re.sub(
    r't\.get\(\s*([\"\'])columns\1\s*,\s*\[\]\s*,\s*default\s*=\s*_jd\s*\)',
    r't.get(\1columns\1, [])',
    s
)
s = re.sub(
    r't\.get\(\s*([\"\'])samples\1\s*,\s*\{\}\s*,\s*default\s*=\s*_jd\s*\)',
    r't.get(\1samples\1, {})',
    s
)

# 2) Ensure json.dumps for columns/samples uses default=_jd (once, on json.dumps only)
#   columns
s = re.sub(
    r'json\.dumps\(\s*t\.get\(\s*([\"\'])columns\1\s*,\s*\[\]\s*\)\s*\)',
    r'json.dumps(t.get(\1columns\1, []), default=_jd)',
    s
)
#   samples
s = re.sub(
    r'json\.dumps\(\s*t\.get\(\s*([\"\'])samples\1\s*,\s*\{\}\s*\)\s*\)',
    r'json.dumps(t.get(\1samples\1, {}), default=_jd)',
    s
)

# 3) As a safety net, if any json.dumps(...columns...) lacks default, add it
s = re.sub(
    r'(json\.dumps\(\s*[^)]*columns[^)]*)(\))',
    lambda m: m.group(1) + (', default=_jd' if 'default=_jd' not in m.group(1) else '') + m.group(2),
    s
)
#    and for samples
s = re.sub(
    r'(json\.dumps\(\s*[^)]*samples[^)]*)(\))',
    lambda m: m.group(1) + (', default=_jd' if 'default=_jd' not in m.group(1) else '') + m.group(2),
    s
)

p.write_text(s)
print(f"patched: {p}")
PY

echo ">> Rebuild & restart API"
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
head -n 40 "$body" | jq . 2>/dev/null || sed -n '1,120p' "$body"

if [[ "$code" != "200" || "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards not OK. Last API logs:"
  docker compose logs --tail 200 api
  exit 1
fi

echo ">> Quick preview sanity"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ schema/cards fixed and healthy."
