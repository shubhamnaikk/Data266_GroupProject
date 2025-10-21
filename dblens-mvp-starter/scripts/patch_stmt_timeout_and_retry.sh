#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}

echo ">> Patch any '$1' / '%s' / '?' placeholders used with SET statement_timeout to a literal (5000)"
python3 - <<'PY'
from pathlib import Path
import re

# patch both locations if present
roots = [Path("services/ingester"), Path("connectors")]
patched = 0

patterns = [
    re.compile(r'(SET\s+LOCAL\s+statement_timeout\s*(?:=|TO)\s*)(?:\$[0-9]+|%s|\?)', re.IGNORECASE),
    re.compile(r'(SET\s+statement_timeout\s*(?:=|TO)\s*)(?:\$[0-9]+|%s|\?)', re.IGNORECASE),
]

def patch_file(p: Path):
    global patched
    s = p.read_text()
    orig = s
    for pat in patterns:
        s = pat.sub(r'\g<1>5000', s)
    if s != orig:
        p.write_text(s)
        print(f"patched: {p}")
        patched += 1

for root in roots:
    if not root.exists():
        continue
    for p in root.rglob("*.py"):
        # be conservative: only patch connector/api files
        if any(seg in {"connector", "connectors", "api"} for seg in p.parts):
            try:
                patch_file(p)
            except Exception as e:
                print(f"skip {p}: {e}")

print(f"files_patched={patched}")
PY

echo ">> Rebuild API and restart"
docker compose build api
docker compose up -d api

echo ">> Wait for API"
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API is up"; break; }
  sleep 0.5
  [[ $i -eq 40 ]] && { echo "✘ API not responding"; docker compose logs --tail 120 api; exit 1; }
done

echo ">> Create a pg-local connection (idempotent name)"
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}
resp=$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}" || true)
echo "$resp"

conn_id=$(python3 - <<'PY' "$resp"
import json,sys
try:
    j=json.loads(sys.argv[1]); print(j.get("id",""))
except: print("")
PY
)
if [[ -z "$conn_id" ]]; then
  echo "!! Couldn't get connection id; showing API logs"
  docker compose logs --tail 120 api
  exit 1
fi
echo "conn_id=$conn_id"

echo ">> /connections/test"
curl -s "$API/connections/test" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | jq .

echo ">> /schema/cards"
curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40

echo ">> /preview (select 1)"
curl -s "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ Patch + smoke complete"
