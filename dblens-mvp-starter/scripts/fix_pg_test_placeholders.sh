#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}

echo ">> Patch Postgres test: drop params when setting statement_timeout"
python3 - <<'PY'
from pathlib import Path
import re

roots = [Path("connectors"), Path("services/ingester")]
patched = 0

# Replace any cur.execute("SET [LOCAL] statement_timeout ...", <params>) with literal, no params.
pattern = re.compile(
    r"""execute\(\s*  # execute(
        (['"])        # quote
        \s*SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*.*?\1  # 'SET ... statement_timeout ...'
        \s*,\s*       # , params
        [^)]+         # anything until )
        \)""",
    re.IGNORECASE | re.VERBOSE,
)

def patch_file(p: Path):
    global patched
    s = p.read_text()
    new = pattern.sub('execute("SET LOCAL statement_timeout = 5000")', s)
    if new != s:
        p.write_text(new)
        print("patched:", p)
        patched += 1

for root in roots:
    if not root.exists(): continue
    for f in root.rglob("*.py"):
        # only touch connector/api code paths
        if not any(seg in {"connectors","connector","api"} for seg in f.parts): 
            continue
        try:
            patch_file(f)
        except Exception as e:
            print("skip", f, e)

print("files_patched=", patched)
PY

echo ">> Rebuild API and restart"
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
resp=$(curl -s -X POST "$API/connections" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"

conn_id=$(echo "$resp" | jq -r '.id // empty')
if [[ -z "$conn_id" ]]; then
  echo "!! Could not parse conn_id. Last API logs:"
  docker compose logs --tail 150 api
  exit 1
fi
echo "conn_id=$conn_id"

echo ">> /connections/test (should be ok now)"
curl -s "$API/connections/test" \
  -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | jq .

echo ">> /schema/cards (first 40 lines)"
curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40

echo ">> /preview (select 1)"
curl -s "$API/preview" \
  -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ Placeholder fix + smoke complete"
