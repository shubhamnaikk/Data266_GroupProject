#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_URL_RW="postgresql://loader_rw:loader_rw_pass@localhost:5432/dblens"

echo "== Grant sequence privileges for connections_id_seq to loader_rw =="
docker compose exec -T postgres psql -U postgres -d dblens -v ON_ERROR_STOP=1 <<'SQL'
-- grant for existing sequence
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE c.relkind='S' AND n.nspname='public' AND c.relname='connections_id_seq') THEN
    GRANT USAGE, SELECT ON SEQUENCE public.connections_id_seq TO loader_rw;
  END IF;
END$$;

-- set sane defaults for future sequences created by postgres in public
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public
GRANT USAGE, SELECT ON SEQUENCES TO loader_rw;
SQL
echo "✔ Sequence grants applied"

echo "== Smoke: insert/delete via loader_rw directly =="
docker compose exec -T postgres psql "$PG_URL_RW" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.connections(name,driver,dsn)
VALUES ('cp-smoke-tmp','postgres','postgresql://app_ro:app_ro_pass@postgres:5432/dblens')
RETURNING id;
DELETE FROM public.connections WHERE name='cp-smoke-tmp';
SQL

echo "== Try POST /connections again =="
resp="$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}' || true)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d '{"name":"pg-local","driver":"postgres","dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}' || true)"

echo "HTTP $code"
echo "$resp"

# If JSON, show id with jq (if installed)
if command -v jq >/dev/null 2>&1; then
  echo "$resp" | jq . 2>/dev/null || true
fi

if [[ "$code" != "200" ]]; then
  echo "!! Still failing, showing last API logs:"
  docker compose logs --tail 120 api
  exit 1
fi

# Optional: test /connections/test
conn_id="$(printf '%s' "$resp" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
if [[ -n "$conn_id" ]]; then
  echo "== /connections/test on conn_id=$conn_id =="
  curl -s "$API/connections/test" -H 'Content-Type: application/json' -d "{\"conn_id\":$conn_id}" | jq .
  echo "== /schema/cards =="
  curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40
fi

echo "✔ /connections is working"
