-- Create read-only and loader roles with secure defaults
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'loader_rw') THEN
      CREATE ROLE loader_rw LOGIN PASSWORD 'loader_rw_pass';
   END IF;
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ro') THEN
      CREATE ROLE app_ro LOGIN PASSWORD 'app_ro_pass';
   END IF;
END
$$;

-- Ensure both roles can connect and use public schema
GRANT CONNECT ON DATABASE dblens TO loader_rw, app_ro;
GRANT USAGE ON SCHEMA public TO loader_rw, app_ro;

-- Loader can create tables for ingestion
GRANT CREATE ON SCHEMA public TO loader_rw;

-- App role is read-only by default
ALTER ROLE app_ro SET default_transaction_read_only = on;
ALTER ROLE app_ro SET statement_timeout = '5s';
ALTER ROLE app_ro SET work_mem = '8MB';
ALTER ROLE app_ro SET search_path = public;

-- Optional: keep loader flexible but set sane timeouts
ALTER ROLE loader_rw SET search_path = public;
ALTER ROLE loader_rw SET statement_timeout = '60s';

-- Tighten default privileges: only owner has rights unless granted
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_ro;

-- Ingestion provenance table
CREATE TABLE IF NOT EXISTS ingestion_log (
  id           bigserial PRIMARY KEY,
  url          text NOT NULL,
  table_name   text NOT NULL,
  format       text NOT NULL,
  row_count    bigint,
  bytes        bigint,
  sha256       text,
  columns_json jsonb,
  errors_json  jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE ingestion_log IS 'Provenance records for URL ingestions';
-- Allow loader/app to write/read provenance
GRANT INSERT, SELECT ON public.ingestion_log TO loader_rw, app_ro;

-- Default privileges for NEW sequences created by 'postgres' in public
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO loader_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT        ON SEQUENCES TO app_ro;

-- Ensure tables/sequences created by loader_rw auto-grant to app_ro
ALTER DEFAULT PRIVILEGES FOR ROLE loader_rw IN SCHEMA public
  GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE loader_rw IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO app_ro;

-- === Audit table for Approve step ===
CREATE TABLE IF NOT EXISTS audit_events (
  id              bigserial PRIMARY KEY,
  user_question   text,
  sql_text        text NOT NULL,
  explain_json    jsonb,
  preview_hash    text,
  row_count       bigint,
  result_limited  boolean DEFAULT true,
  schema_snapshot jsonb,
  url_provenance  jsonb,
  approval_ts     timestamptz NOT NULL DEFAULT now()
);

-- Read results, write inserts
GRANT INSERT, SELECT ON public.audit_events TO loader_rw;
GRANT SELECT ON public.audit_events TO app_ro;

-- Sequences for audit_events
GRANT USAGE, SELECT ON SEQUENCE public.audit_events_id_seq TO loader_rw;
GRANT SELECT ON SEQUENCE public.audit_events_id_seq TO app_ro;

-- Enforce read-only posture for app_ro (schema+temp)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM app_ro;
GRANT  USAGE ON SCHEMA public TO app_ro;
GRANT  USAGE, CREATE ON SCHEMA public TO loader_rw;

REVOKE TEMP ON DATABASE dblens FROM PUBLIC;
REVOKE TEMP ON DATABASE dblens FROM app_ro;
GRANT  TEMP ON DATABASE dblens TO loader_rw;
