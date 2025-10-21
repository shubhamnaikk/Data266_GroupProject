#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Patching any parameterized SET statement_timeout calls to a param-less literal (5000 ms)"
python3 - <<'PY'
import re
from pathlib import Path

roots = [Path("connectors"), Path("services/ingester")]
patched = 0

# 1) Replace any execute("...statement_timeout...", params) with execute("SET LOCAL statement_timeout = 5000")
pat_exec_with_params = re.compile(
    r'''execute\(\s*                # execute(
        (["\'])                     # opening quote
        \s*SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*[^"']*?\1  # SQL string with statement_timeout
        \s*,\s*                     # , params
        [^)]+                       # params blob
        \)                          # )
    ''',
    re.IGNORECASE | re.VERBOSE | re.DOTALL
)

# 2) Replace any placeholders inside the SQL itself ($1 / %s / ?) with literal 5000
pat_placeholders_in_sql = re.compile(
    r'((?:SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*))(\$[0-9]+|%s|\?)',
    re.IGNORECASE
)

for root in roots:
    if not root.exists():
        continue
    for p in root.rglob("*.py"):
        s = p.read_text()
        orig = s
        s = pat_exec_with_params.sub('execute("SET LOCAL statement_timeout = 5000")', s)
        s = pat_placeholders_in_sql.sub(r'\g<1>5000', s)
        if s != orig:
            p.write_text(s)
            print(f"patched: {p}")
            patched += 1

print(f"files_patched={patched}")
PY

echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API"
for i in {1..60}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API is up"; break; }
  sleep 0.5
  [[ $i -eq 60 ]] && { echo "✘ API not responding"; docker compose logs --tail 120 api; exit 1; }
done

echo ">> Create/ensure pg-local connection"
resp=$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | jq -r '.id // empty')
[[ -n "$conn_id" ]] || { echo "!! could not parse conn_id"; docker compose logs --tail 120 api; exit 1; }
echo "conn_id=$conn_id"

echo ">> /connections/test (should be ok now)"
curl -s "$API/connections/test" -H 'Content-Type: application/json' -d "{\"conn_id\":$conn_id}" | jq .

echo ">> /schema/cards (first 40 lines)"
curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40 || true

echo ">> /preview (select 1)"
curl -s "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ statement_timeout patch + smoke complete"
