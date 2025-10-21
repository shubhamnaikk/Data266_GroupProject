#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}

echo ">> Find files that set statement_timeout"
FILES=$(grep -RIl --include='*.py' -E 'SET[[:space:]]+(LOCAL[[:space:]]+)?statement_timeout' \
  connectors services/ingester || true)
echo "$FILES"

if [[ -z "${FILES:-}" ]]; then
  echo "No files contain statement_timeout. Showing API logs:"
  docker compose logs --tail 150 api
  exit 1
fi

echo ">> Patch execute('SET ... statement_timeout ...', params) -> execute('SET LOCAL statement_timeout = 5000')"
python3 - "$FILES" <<'PY'
import sys, re, pathlib
files = sys.argv[1:]
# pattern: execute("...statement_timeout...", <anything params>)
pat = re.compile(
    r'''execute\(\s*     # execute(
        (["\'])          # opening quote
        \s*SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*[^"']*?\1 # SQL string with statement_timeout
        \s*,\s*          # comma = parameters
        [^)]+            # params blob
        \)               # )
    ''',
    re.IGNORECASE | re.VERBOSE | re.DOTALL
)
for fp in files:
    p = pathlib.Path(fp)
    s = p.read_text()
    s2 = pat.sub('execute("SET LOCAL statement_timeout = 5000")', s)
    if s2 != s:
        p.write_text(s2)
        print(f"patched: {fp}")
print("done")
PY

echo ">> Rebuild & restart API"
docker compose build api
docker compose up -d api

echo ">> Wait for API"
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API is up"; break; }
  sleep 0.5
  [[ $i -eq 40 ]] && { echo "✘ API not responding"; docker compose logs --tail 150 api; exit 1; }
done

echo ">> Create/ensure pg-local connection"
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}
resp=$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | jq -r '.id // empty'); echo "conn_id=$conn_id"

echo ">> /connections/test"
curl -s "$API/connections/test" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | jq .

echo ">> /schema/cards"
curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40

echo ">> /preview"
curl -s "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ Timeout call fixed and smoke passed (if the above were 200)."
