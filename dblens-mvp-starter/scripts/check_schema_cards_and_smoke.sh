#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

j() { command -v jq >/dev/null 2>&1 && jq . || cat; }

echo "== 0) Ensure API is up =="
for i in {1..40}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [[ $i -eq 40 ]] && { echo "✘ API not responding"; docker compose logs --tail 120 api; exit 1; }
done

echo "== 1) Create/ensure a Postgres connection (pg-local) =="
resp=$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp" | j
conn_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || true)
[[ -n "${conn_id:-}" ]] || { echo "✘ Could not parse conn_id from /connections"; exit 1; }
echo "conn_id=$conn_id"

echo "== 2) /connections/test =="
curl -sS "$API/connections/test" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | j

echo "== 3) /schema/cards — try GET (query param) =="
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
sed -n '1,200p' "$body" | j | sed -n '1,40p' || true

CARDS_OK=0
if [[ "$code" == "200" && "$ctype" == *"application/json"* ]]; then
  CARDS_OK=1
else
  echo "== 3b) /schema/cards — try POST (JSON body) =="
  hdr2=$(mktemp); body2=$(mktemp)
  code2=$(curl -sS -D "$hdr2" -o "$body2" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "{\"conn_id\": $conn_id}" \
    "$API/schema/cards" || echo "000")
  ctype2=$(grep -i '^content-type:' "$hdr2" | tr -d '\r' | awk '{print tolower($0)}' || true)
  echo "HTTP $code2 | $ctype2"
  sed -n '1,200p' "$body2" | j | sed -n '1,40p' || true
  if [[ "$code2" == "200" && "$ctype2" == *"application/json"* ]]; then
    CARDS_OK=1
  fi
fi

if [[ "$CARDS_OK" -ne 1 ]]; then
  echo "✘ /schema/cards did not return JSON 200. Last API logs:"
  docker compose logs --tail 150 api
  exit 1
fi

echo "== 4) /preview (select 1) =="
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | j

echo "== 5) /validate (sample query on airtravel if present) =="
curl -sS "$API/validate" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select * from airtravel limit 5\"}" | j || true

echo "== 6) /approve (audited read-only exec) =="
curl -sS "$API/approve" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select * from airtravel limit 5\",\"question\":\"connector smoke\"}" | j || true

echo "✔ Done."
