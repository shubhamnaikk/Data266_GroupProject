#!/usr/bin/env bash
set -euo pipefail

base="http://localhost:8000"

say(){ printf "%s\n" "$*"; }

# 0) API up
say "== 0) API up =="
for i in $(seq 1 40); do
  if curl -fsS "$base/openapi.json" >/dev/null; then
    say "✔ API reachable"
    break
  fi
  sleep 0.5
  test "$i" -eq 40 && { say "✘ API not responding"; exit 1; }
done

# 1) Create/ensure a Postgres connection (local app_ro)
say "== 1) Create/ensure pg-local connection =="
create_resp="$(curl -sS -X POST "$base/connections" \
  -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}')"
CID="$(printf "%s" "$create_resp" | jq -r '.id // empty')"
test -n "${CID:-}" || { echo "$create_resp"; echo "✘ Could not parse conn_id"; exit 1; }
say "conn_id=$CID"

# 2) /connections/test
say "== 2) /connections/test =="
conn_test="$(curl -sS -X POST "$base/connections/test" -H 'Content-Type: application/json' -d "{\"conn_id\":$CID}")"
echo "$conn_test" > /tmp/conn_test.json
if jq -e '.ok==true' /tmp/conn_test.json >/dev/null 2>&1; then
  say "✔ connection ok"
else
  say "✘ connection test failed"
  cat /tmp/conn_test.json
  exit 1
fi

# 3) /schema/cards
say "== 3) /schema/cards (GET) =="
code=$(curl -sS -w '%{http_code}' -o /tmp/cards.json "$base/schema/cards?conn_id=${CID}")
if [ "$code" != "200" ]; then
  echo "HTTP $code"; echo "✘ /schema/cards failed"; docker compose logs --tail 120 api; exit 1
fi
head -c 400 /tmp/cards.json; echo
jq -e 'has("SchemaCard")' /tmp/cards.json >/dev/null && say "✔ schema cards ok" || { say "✘ schema cards payload unexpected"; exit 1; }

# 4) /preview — try with conn_id query param first, then fallback
say "== 4) /preview (SELECT count(*) FROM airtravel) =="
payload='{"sql":"select count(*) from airtravel"}'
code=$(curl -sS -w '%{http_code}' -o /tmp/prev.json -X POST "$base/preview?conn_id=${CID}" -H 'Content-Type: application/json' -d "$payload")
if [ "$code" != "200" ]; then
  code=$(curl -sS -w '%{http_code}' -o /tmp/prev.json -X POST "$base/preview" -H 'Content-Type: application/json' -d "{\"conn_id\":$CID,\"sql\":\"select count(*) from airtravel\"}")
fi
if [ "$code" != "200" ]; then
  echo "HTTP $code"; cat /tmp/prev.json; echo; echo "✘ /preview failed"; exit 1
fi
cat /tmp/prev.json; echo
say "✔ preview ok"

# 5) /validate — same dual style
say "== 5) /validate =="
val_payload="{\"sql\":\"select * from airtravel limit 5\"}"
code=$(curl -sS -w '%{http_code}' -o /tmp/val.json -X POST "$base/validate?conn_id=${CID}" -H 'Content-Type: application/json' -d "$val_payload")
if [ "$code" != "200" ]; then
  code=$(curl -sS -w '%{http_code}' -o /tmp/val.json -X POST "$base/validate" -H 'Content-Type: application/json' -d "{\"conn_id\":$CID,\"sql\":\"select * from airtravel limit 5\"}")
fi
if [ "$code" != "200" ]; then
  echo "HTTP $code"; cat /tmp/val.json; echo; echo "✘ /validate failed"; exit 1
fi
jq -r '.total_cost,.est_rows' /tmp/val.json 2>/dev/null || true
say "✔ validate ok"

# 6) /approve — inserts an audit row
say "== 6) /approve =="
approve_body="{\"sql\":\"select * from airtravel limit 5\",\"question\":\"connector smoke\",\"conn_id\":$CID}"
code=$(curl -sS -w '%{http_code}' -o /tmp/app.json -X POST "$base/approve?conn_id=${CID}" -H 'Content-Type: application/json' -d "$approve_body")
if [ "$code" != "200" ] || ! jq -e '.ok==true' /tmp/app.json >/dev/null 2>&1; then
  echo "HTTP $code"; cat /tmp/app.json; echo; echo "✘ /approve failed"; exit 1
fi
say "✔ approve ok"

# 7) Quick DB sanity for audit row
say "== 7) audit_events sanity =="
docker compose exec -T postgres psql -U postgres -d dblens -c "select id, user_question, row_count, approval_ts from audit_events order by id desc limit 3;" || true

say "✔ End-to-end connector smoke passed"
