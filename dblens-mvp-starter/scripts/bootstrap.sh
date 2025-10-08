#!/usr/bin/env bash
# scripts/bootstrap.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m'); NC=$(printf '\033[0m')
pass(){ echo "${GRN}✔ $*${NC}"; }
warn(){ echo "${YLW}△ $*${NC}"; }
fail(){ echo "${RED}✘ $*${NC}"; exit 1; }

#---- 0) .env presence ---------------------------------------------------------
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    echo "No .env found, creating from .env.example"
    cp .env.example .env
  else
    fail "Missing .env and .env.example. Please create .env."
  fi
else
  echo "Using existing .env"
fi

#---- 1) Build & start ---------------------------------------------------------
echo "Building and starting containers..."
docker compose up -d --build postgres ingester api >/dev/null || fail "docker compose up failed"
pass "Compose services started (postgres, ingester, api)"

#---- 2) Wait for Postgres health ---------------------------------------------
echo "Waiting for Postgres to be healthy..."
CID="$(docker compose ps -q postgres)"
if [[ -z "$CID" ]]; then fail "postgres container not found"; fi

for i in {1..60}; do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo "unknown")"
  if [[ "$status" == "healthy" ]]; then
    pass "Postgres is ready."
    break
  fi
  sleep 1
  [[ $i -eq 60 ]] && fail "Postgres did not become healthy in time"
done

# psql helper
PSQL="docker compose exec -T postgres psql -q -X -U postgres -d dblens -v ON_ERROR_STOP=1 -c"

#---- 3) Ensure roles / grants / tables (idempotent) ---------------------------
echo "Applying idempotent DB bootstrap (roles, grants, system tables)..."
$PSQL "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='loader_rw') THEN
    CREATE ROLE loader_rw LOGIN PASSWORD 'loader_rw_pass' INHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='app_ro') THEN
    CREATE ROLE app_ro LOGIN PASSWORD 'app_ro_pass' INHERIT;
  END IF;
END\$\$;

GRANT CONNECT ON DATABASE dblens TO loader_rw, app_ro;

-- Schema posture
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM app_ro;
GRANT  USAGE ON SCHEMA public TO app_ro;
GRANT  USAGE, CREATE ON SCHEMA public TO loader_rw;

-- Temp posture
REVOKE TEMP ON DATABASE dblens FROM PUBLIC;
REVOKE TEMP ON DATABASE dblens FROM app_ro;
GRANT  TEMP ON DATABASE dblens TO loader_rw;

-- System tables
CREATE TABLE IF NOT EXISTS public.ingestion_log(
  id           bigserial PRIMARY KEY,
  url          text NOT NULL,
  table_name   text NOT NULL,
  format       text NOT NULL,
  row_count    bigint NOT NULL,
  bytes        bigint NOT NULL,
  sha256       text,
  columns_json jsonb,
  errors_json  jsonb,
  created_at   timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audit_events(
  id              bigserial PRIMARY KEY,
  user_question   text,
  sql_text        text NOT NULL,
  explain_json    jsonb,
  preview_hash    text,
  row_count       bigint,
  result_limited  boolean DEFAULT true,
  schema_snapshot jsonb,
  url_provenance  jsonb,
  approval_ts     timestamptz DEFAULT now()
);

-- Grants
GRANT SELECT                ON public.ingestion_log TO app_ro;
GRANT INSERT, SELECT       ON public.ingestion_log TO loader_rw;
GRANT USAGE, SELECT        ON SEQUENCE public.ingestion_log_id_seq TO loader_rw;

GRANT SELECT                ON public.audit_events TO app_ro;
GRANT INSERT, SELECT       ON public.audit_events TO loader_rw;
GRANT USAGE, SELECT        ON SEQUENCE public.audit_events_id_seq TO loader_rw;

-- Default privileges for future tables/sequences created by loader_rw
ALTER DEFAULT PRIVILEGES FOR ROLE loader_rw IN SCHEMA public
  GRANT SELECT ON TABLES    TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE loader_rw IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_ro;

-- Sensible timeouts for read paths

-- Role-scoped timeouts (safer than ALTER SYSTEM)
ALTER ROLE app_ro    SET statement_timeout = '15s';
ALTER ROLE loader_rw SET statement_timeout = '30s';
"

pass "Roles, tables, and grants are in place."

#---- 4) Show quick smoke info -------------------------------------------------
echo "Smoke check: list roles"
docker compose exec -T postgres psql -U postgres -d dblens -c "\du app_ro loader_rw" || true

# API routes (if api is running)
echo "Checking API routes..."
OPENAPI="$(mktemp)"
HTTP="$(curl -sS -w '%{http_code}' -o "$OPENAPI" http://localhost:8000/openapi.json || true)"
if [[ "$HTTP" == "200" && -s "$OPENAPI" ]]; then
  echo "Registered endpoints:"
  python3 - "$OPENAPI" <<'PY'
import sys, json
try:
  j=json.load(open(sys.argv[1],"rb"))
  for p in sorted(j.get("paths",{}).keys()):
    print(" -", p)
except Exception as e:
  print(" (could not parse openapi.json:", e, ")")
PY
  pass "API reachable at http://localhost:8000"
else
  warn "API not reachable yet (HTTP $HTTP). You can check later at http://localhost:8000/docs"
fi
rm -f "$OPENAPI"

cat <<'NOTE'

Next steps:

1) Ingest sample data
   make ingest URL="https://people.sc.fsu.edu/~jburkardt/data/csv/airtravel.csv" TABLE=airtravel FORMAT=csv ARGS="--if-exists replace"

2) Explore schema
   curl -s http://localhost:8000/schema/cards | jq .

3) Preview & Validate
   curl -s http://localhost:8000/preview  -H 'Content-Type: application/json' -d '{"sql":"select count(*) from airtravel"}' | jq .
   curl -s http://localhost:8000/validate -H 'Content-Type: application/json' -d '{"sql":"select * from airtravel limit 5"}' | jq .

4) Approve (executes read-only and audits)
   curl -s http://localhost:8000/approve  -H 'Content-Type: application/json' -d '{"sql":"select * from airtravel limit 5","question":"sanity"}' | jq .

Health check (all-in-one):
   bash scripts/health_check_v6.sh

NOTE
