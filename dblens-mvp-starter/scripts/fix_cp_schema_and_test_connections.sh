#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}

echo "== Ensure control-plane schema exists (connections, schema_card_cache, audit_events cols) =="

docker compose exec -T postgres psql -U postgres -d dblens -v ON_ERROR_STOP=1 <<'SQL'
-- connections registry
CREATE TABLE IF NOT EXISTS public.connections (
  id                  bigserial PRIMARY KEY,
  name                text NOT NULL,
  driver              text NOT NULL CHECK (driver IN ('postgres','mysql','snowflake')),
  dsn                 text,
  secret_ref          text,
  read_only_verified  boolean DEFAULT false,
  features_json       jsonb,
  created_at          timestamptz DEFAULT now(),
  last_tested_at      timestamptz
);

-- schema card cache
CREATE TABLE IF NOT EXISTS public.schema_card_cache (
  conn_id        bigint REFERENCES public.connections(id) ON DELETE CASCADE,
  table_fqn      text   NOT NULL,
  columns_json   jsonb  NOT NULL,
  samples_json   jsonb,
  refreshed_at   timestamptz DEFAULT now(),
  version        text DEFAULT 'v1',
  PRIMARY KEY (conn_id, table_fqn)
);

-- extend audit_events (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='audit_events' AND column_name='conn_id') THEN
    ALTER TABLE public.audit_events ADD COLUMN conn_id bigint REFERENCES public.connections(id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='audit_events' AND column_name='engine') THEN
    ALTER TABLE public.audit_events ADD COLUMN engine text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='audit_events' AND column_name='database') THEN
    ALTER TABLE public.audit_events ADD COLUMN database text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='audit_events' AND column_name='schema') THEN
    ALTER TABLE public.audit_events ADD COLUMN schema text;
  END IF;
END$$;

-- grants: loader_rw manages registry/cache; app_ro can read cache
GRANT INSERT, UPDATE, SELECT, DELETE ON public.connections TO loader_rw;
GRANT INSERT, UPDATE, SELECT, DELETE ON public.schema_card_cache TO loader_rw;
GRANT SELECT ON public.schema_card_cache TO app_ro;
SQL

echo "== Quick sanity: list tables =="
docker compose exec -T postgres psql -U postgres -d dblens -c "\dt public.*" | sed -n '1,200p'

echo "== Restart API (ensure it picks up any env/grants) =="
docker compose up -d api >/dev/null 2>&1 || true
# wait briefly for reload
for i in {1..30}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && break
  sleep 0.3
done

echo "== Try POST /connections (pg-local smoke) =="
PG_TEST_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}
resp=$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_TEST_DSN\"}" || true)
echo "$resp"

# extract id if present
conn_id=$(python3 - <<'PY'
import json,sys
try:
    j=json.loads(sys.stdin.read())
    print(j.get("id",""))
except: print("")
PY <<<"$resp")

if [[ -n "$conn_id" ]]; then
  echo "== Test /connections/test on conn_id=$conn_id =="
  curl -s "$API/connections/test" -H 'Content-Type: application/json' -d "{\"conn_id\":$conn_id}" | jq .
  echo "== Schema cards for conn_id=$conn_id =="
  curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40
  echo "== Preview simple query =="
  curl -s "$API/preview" -H 'Content-Type: application/json' -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .
else
  echo "!! Still failing to create a connection. Showing last API logs:"
  docker compose logs --tail 120 api
  exit 1
fi

echo "✔ Control-plane schema + /connections flow looks good."
