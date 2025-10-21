#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

j() { command -v jq >/dev/null 2>&1 && jq . || cat; }

echo "== 0) Ensure API up =="
for i in $(seq 1 40); do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [ "$code" = "200" ] && { echo "✔ API reachable"; break; }
  sleep 0.4
  [ $i -eq 40 ] && { echo "✘ API not responding"; docker compose logs --tail 150 api; exit 1; }
done

echo "== 1) Create/ensure pg-local connection =="
resp="$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")"
echo "$resp" | j

# Robust conn_id extraction: jq -> python3 -> sed
conn_id=""
if command -v jq >/dev/null 2>&1; then
  conn_id="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
fi
if [ -z "${conn_id:-}" ] && command -v python3 >/dev/null 2>&1; then
  conn_id="$(printf '%s' "$resp" | python3 - "$@" <<'PY'
import sys, json
try:
    obj=json.load(sys.stdin)
    cid=obj.get("id")
    if cid is not None: print(cid)
except Exception:
    pass
PY
)"
fi
if [ -z "${conn_id:-}" ]; then
  conn_id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
fi
[ -n "${conn_id:-}" ] || { echo "✘ no conn_id parsed from /connections"; exit 1; }
echo "conn_id=$conn_id"

echo "== 2) /connections/test =="
curl -sS "$API/connections/test" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | j

echo "== 3) GET /schema/cards =="
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
head -n 50 "$body" | j 2>/dev/null || sed -n '1,120p' "$body"

if [ "$code" != "200" ] || [[ "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards not OK. API log tail:"
  docker compose logs --tail 200 api
  exit 1
fi

echo "== 4) /preview sanity =="
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | j

echo "== 5) /validate (airtravel if present) =="
curl -sS "$API/validate" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select * from airtravel limit 3\"}" | j || true

echo "== 6) /approve (audited) =="
curl -sS "$API/approve" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select * from airtravel limit 3\",\"question\":\"schema-cards smoke\"}" | j || true

echo "✔ Done."
