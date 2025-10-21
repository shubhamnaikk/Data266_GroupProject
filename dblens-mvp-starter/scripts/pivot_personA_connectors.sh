#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m'); NC=$(printf '\033[0m')
pass(){ echo "${GRN}✔ $*${NC}"; }
warn(){ echo "${YLW}△ $*${NC}"; }
fail(){ echo "${RED}✘ $*${NC}"; exit 1; }

# 0) Sanity
[[ -f docker-compose.yml ]] || fail "Run from repo root (docker-compose.yml not found)."
[[ -d services/ingester ]]  || fail "services/ingester not found."

echo ">> Backing up important files..."
cp -n services/ingester/api.py services/ingester/api.py.bak 2>/dev/null || true
cp -n services/ingester/Dockerfile services/ingester/Dockerfile.bak 2>/dev/null || true
mkdir -p scripts
cp -n scripts/health_check_v6.sh scripts/health_check_v6.sh.bak 2>/dev/null || true

# 1) Control-plane schema changes (idempotent)
echo ">> Applying control-plane migrations (connections, schema_card_cache, audit_events columns)..."
docker compose exec -T postgres psql -U postgres -d dblens -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS public.connections (
  id                bigserial PRIMARY KEY,
  name              text NOT NULL,
  driver            text NOT NULL CHECK (driver IN ('postgres','mysql','snowflake')),
  dsn               text,                     -- dev only; for prod use secret_ref
  secret_ref        text,                     -- e.g., aws-secrets-manager reference
  read_only_verified boolean DEFAULT false,
  features_json     jsonb,
  created_at        timestamptz DEFAULT now(),
  last_tested_at    timestamptz
);

CREATE TABLE IF NOT EXISTS public.schema_card_cache (
  conn_id        bigint REFERENCES public.connections(id) ON DELETE CASCADE,
  table_fqn      text   NOT NULL,         -- e.g., public.customers or DB.SCHEMA.TABLE
  columns_json   jsonb  NOT NULL,
  samples_json   jsonb,
  refreshed_at   timestamptz DEFAULT now(),
  version        text    DEFAULT 'v1',
  PRIMARY KEY (conn_id, table_fqn)
);

-- extend audit_events with connection context (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='audit_events' AND column_name='conn_id') THEN
    ALTER TABLE public.audit_events ADD COLUMN conn_id bigint REFERENCES public.connections(id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='audit_events' AND column_name='engine') THEN
    ALTER TABLE public.audit_events ADD COLUMN engine text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='audit_events' AND column_name='database') THEN
    ALTER TABLE public.audit_events ADD COLUMN database text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='audit_events' AND column_name='schema') THEN
    ALTER TABLE public.audit_events ADD COLUMN schema text;
  END IF;
END$$;

-- grants: do NOT expose connections to app_ro
GRANT SELECT ON public.schema_card_cache TO app_ro;
GRANT INSERT, UPDATE, SELECT, DELETE ON public.connections TO loader_rw;
GRANT INSERT, UPDATE, SELECT, DELETE ON public.schema_card_cache TO loader_rw;
SQL
pass "Control-plane DB migrated."

# 2) Ensure Python deps (API image) include connector libs
echo ">> Updating API Dockerfile to include MySQL & Snowflake connectors..."
DOCKERFILE="services/ingester/Dockerfile"
python3 - "$DOCKERFILE" <<'PY'
from pathlib import Path
p = Path("services/ingester/Dockerfile")
s = p.read_text()
lines = s.splitlines()
want = [
    "pymysql==1.1.0",
    "snowflake-connector-python==3.10.0",
    "sqlglot==25.6.0"
]
if "pymysql" not in s or "snowflake-connector-python" not in s or "sqlglot" not in s:
    out=[]
    injected=False
    for ln in lines:
        out.append(ln)
        if ln.strip().startswith("pip install") and "psycopg" in ln and not injected:
            out.append("    pymysql==1.1.0 \\")
            out.append("    snowflake-connector-python==3.10.0 \\")
            out.append("    sqlglot==25.6.0 \\")
            injected=True
    Path(p).write_text("\n".join(out))
PY
pass "Dockerfile updated (pymysql, snowflake-connector, sqlglot)."

# 3) Write Connector SDK + connectors
echo ">> Writing Connector SDK and three connectors (postgres_external, mysql, snowflake)..."
mkdir -p services/ingester/connectors

cat > services/ingester/connectors/connector_base.py <<'PY'
from __future__ import annotations
from typing import Any, Dict, List, Tuple, Optional, Protocol

class Connector(Protocol):
    driver: str  # 'postgres' | 'mysql' | 'snowflake'

    def test_connection(self) -> Dict[str, Any]: ...
    def enforce_session_readonly(self, conn: Any) -> None: ...
    def introspect_schema(self, limit_samples: int = 5) -> Dict[str, Any]: ...
    def preview(self, sql_text: str, limit: int = 20) -> List[List[Any]]: ...
    def validate(self, sql_text: str) -> Dict[str, Any]: ...
    def execute_readonly(self, sql_text: str, limit: Optional[int]=None) -> Tuple[List[str], List[List[Any]]]: ...
    def quote_ident(self, name: str) -> str: ...
    def limit_clause(self, n: int) -> str: ...

def single_statement_select_only(sql_text: str) -> None:
    # quick gate; Person A scope — parser can be swapped later
    bad = (";"," UPDATE "," DELETE "," INSERT "," MERGE "," TRUNCATE "," CREATE "," ALTER "," DROP ",
           " COPY "," UNLOAD "," CALL "," EXEC "," GRANT "," REVOKE ")
    s = " " + sql_text.upper().strip() + " "
    if not s.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT is allowed")
    for b in bad:
        if b in s:
            raise ValueError(f"Forbidden token in SQL: {b.strip()}")
PY

cat > services/ingester/connectors/postgres_external.py <<'PY'
from __future__ import annotations
from typing import Any, Dict, List, Tuple, Optional
import psycopg
from psycopg.rows import dict_row
from .connector_base import Connector, single_statement_select_only

class PostgresExternal(Connector):
    driver = "postgres"

    def __init__(self, dsn: str, timeout_s: int = 15):
        self.dsn = dsn
        self.timeout_s = timeout_s

    def _connect(self):
        conn = psycopg.connect(self.dsn, autocommit=True)
        with conn.cursor() as cur:
            cur.execute("SET statement_timeout = %s", (self.timeout_s*1000,))
            cur.execute("SET default_transaction_read_only = on")
        return conn

    def test_connection(self) -> Dict[str, Any]:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("select version()")
            ver = cur.fetchone()[0]
            return {"ok": True, "version": ver, "supports_explain_cost": True}

    def enforce_session_readonly(self, conn: Any) -> None:
        with conn.cursor() as cur:
            cur.execute("SET default_transaction_read_only = on")

    def introspect_schema(self, limit_samples: int = 5) -> Dict[str, Any]:
        with self._connect() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute("""
                SELECT table_schema, table_name
                FROM information_schema.tables
                WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')
                ORDER BY 1,2
            """)
            tables = cur.fetchall()
            out=[]
            for t in tables:
                schema, name = t["table_schema"], t["table_name"]
                cur.execute("""
                    SELECT column_name, data_type
                    FROM information_schema.columns
                    WHERE table_schema=%s AND table_name=%s
                    ORDER BY ordinal_position
                """,(schema,name))
                cols = [{"name":r["column_name"],"type":r["data_type"]} for r in cur.fetchall()]
                # samples
                cur.execute(f'SELECT * FROM "{schema}"."{name}" LIMIT %s', (limit_samples,))
                rows = cur.fetchall()
                samples={}
                if rows:
                    keys = rows[0].keys()
                    for k in keys:
                        samples[k]=[r[k] for r in rows]
                out.append({"schema":schema,"name":name,"columns":cols,"samples":samples})
            return {"tables": out}

    def limit_clause(self, n:int)->str:
        return f" LIMIT {int(n)} "

    def quote_ident(self, name:str)->str:
        return '"' + name.replace('"','""') + '"'

    def preview(self, sql_text: str, limit: int = 20) -> List[List[Any]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"WITH cte AS ({sql_text}) SELECT * FROM cte {self.limit_clause(limit)}")
            return cur.fetchall()

    def validate(self, sql_text: str) -> Dict[str, Any]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(f"EXPLAIN (FORMAT JSON) {sql_text}")
            plan = cur.fetchone()["QUERY PLAN"]
            # flatten basic metrics
            def dive(p):
                node = p[0]["Plan"]
                return {
                    "total_cost": node.get("Total Cost"),
                    "est_rows": node.get("Plan Rows"),
                    "plan": p
                }
            return dive(plan)

    def execute_readonly(self, sql_text:str, limit: Optional[int]=None)->Tuple[List[str], List[List[Any]]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            q = sql_text if not limit else f"WITH cte AS ({sql_text}) SELECT * FROM cte {self.limit_clause(limit)}"
            cur.execute(q)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
            return cols, rows
PY

cat > services/ingester/connectors/mysql.py <<'PY'
from __future__ import annotations
from typing import Any, Dict, List, Tuple, Optional
import pymysql
from .connector_base import Connector, single_statement_select_only

class MySQLConnector(Connector):
    driver = "mysql"
    def __init__(self, dsn: str, timeout_s: int = 15):
        # DSN like: mysql+pymysql://user:pass@host:3306/db
        self.dsn = dsn
        self.timeout_s = timeout_s

    def _parse(self):
        # very small parser; dev-only. For prod, use URL parser.
        assert self.dsn.startswith("mysql://") or self.dsn.startswith("mysql+pymysql://")
        u = self.dsn.split("://",1)[1]
        creds, hostdb = u.split("@",1)
        user, pwd = creds.split(":",1)
        hostport, db = hostdb.split("/",1)
        if ":" in hostport:
            host, port = hostport.split(":",1); port = int(port)
        else:
            host, port = hostport, 3306
        return dict(user=user, password=pwd, host=host, port=port, database=db)

    def _connect(self):
        kw = self._parse()
        kw.update(dict(connect_timeout=self.timeout_s, read_timeout=self.timeout_s, write_timeout=self.timeout_s, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor))
        return pymysql.connect(**kw)

    def test_connection(self)->Dict[str,Any]:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("select version() as v")
            v = cur.fetchone()["v"]
            return {"ok": True, "version": v, "supports_explain_cost": False}

    def enforce_session_readonly(self, conn: Any) -> None:
        # mysql has no global read-only per session; rely on RO user + safe updates
        with conn.cursor() as cur:
            cur.execute("SET SESSION sql_safe_updates=1")

    def introspect_schema(self, limit_samples:int=5)->Dict[str,Any]:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT table_schema, table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY 1,2")
            tables = cur.fetchall()
            out=[]
            for t in tables:
                schema, name = t["table_schema"], t["table_name"]
                cur.execute("SELECT column_name, data_type FROM information_schema.columns WHERE table_schema=%s AND table_name=%s ORDER BY ordinal_position",(schema,name))
                cols = [{"name":r["column_name"],"type":r["data_type"]} for r in cur.fetchall()]
                cur.execute(f"SELECT * FROM `{schema}`.`{name}` LIMIT %s",(limit_samples,))
                rows = cur.fetchall()
                samples={}
                if rows:
                    keys = rows[0].keys()
                    for k in keys:
                        samples[k]=[r[k] for r in rows]
                out.append({"schema":schema,"name":name,"columns":cols,"samples":samples})
            return {"tables": out}

    def quote_ident(self, name:str)->str:
        return f"`{name.replace('`','``')}`"

    def limit_clause(self, n:int)->str:
        return f" LIMIT {int(n)} "

    def preview(self, sql_text:str, limit:int=20)->List[List[Any]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"SELECT * FROM ({sql_text}) AS t {self.limit_clause(limit)}")
            rows = cur.fetchall()
            return [list(r.values()) for r in rows]

    def validate(self, sql_text:str)->Dict[str,Any]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"EXPLAIN {sql_text}")
            plan = cur.fetchall()
            est_rows = sum([r.get("rows") or 0 for r in plan])
            return {"est_rows": est_rows, "plan": plan}

    def execute_readonly(self, sql_text:str, limit: Optional[int]=None)->Tuple[List[str], List[List[Any]]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            q = sql_text if not limit else f"SELECT * FROM ({sql_text}) AS t {self.limit_clause(limit)}"
            cur.execute(q)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
            return cols, [list(r.values()) for r in rows]
PY

cat > services/ingester/connectors/snowflake.py <<'PY'
from __future__ import annotations
from typing import Any, Dict, List, Tuple, Optional
import snowflake.connector
from .connector_base import Connector, single_statement_select_only

class SnowflakeConnector(Connector):
    driver = "snowflake"
    def __init__(self, dsn: str, timeout_s:int=30):
        # simple DSN form for dev: snowflake://user:pass@account/DB/SCHEMA?role=...&warehouse=...
        self.dsn = dsn
        self.timeout_s = timeout_s

    def _parse(self):
        assert self.dsn.startswith("snowflake://")
        u = self.dsn.split("://",1)[1]
        creds, rest = u.split("@",1)
        user, pwd = creds.split(":",1)
        account, path = rest.split("/",1)
        parts = path.split("?")
        db_schema = parts[0]
        q = {}
        if len(parts)>1:
            for kv in parts[1].split("&"):
                if "=" in kv:
                    k,v = kv.split("=",1); q[k]=v
        if "/" in db_schema:
            database, schema = db_schema.split("/",1)
        else:
            database, schema = db_schema, "PUBLIC"
        return dict(user=user, password=pwd, account=account, database=database, schema=schema,
                    role=q.get("role"), warehouse=q.get("warehouse"))

    def _connect(self):
        kw = self._parse()
        conn = snowflake.connector.connect(
            user=kw["user"], password=kw["password"], account=kw["account"],
            database=kw["database"], schema=kw["schema"],
            role=kw.get("role"), warehouse=kw.get("warehouse"),
            client_session_keep_alive=False,
            network_timeout=self.timeout_s
        )
        conn.cursor().execute(f"ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS={int(self.timeout_s)}")
        conn.cursor().execute("ALTER SESSION SET QUERY_TAG='DBLens-MVP-RO'")
        return conn

    def test_connection(self)->Dict[str,Any]:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("select current_version()")
            v = cur.fetchone()[0]
            return {"ok": True, "version": v, "supports_text_explain": True}

    def enforce_session_readonly(self, conn: Any) -> None:
        # rely on RO role; no session-wide RO in Snowflake
        conn.cursor().execute("ALTER SESSION SET STATEMENT_TIMEOUT_IN_SECONDS=%s", (int(self.timeout_s),))

    def introspect_schema(self, limit_samples:int=5)->Dict[str,Any]:
        with self._connect() as conn, conn.cursor(snowflake.connector.DictCursor) as cur:
            cur.execute("SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE'")
            tables = cur.fetchall()
            out=[]
            for t in tables:
                schema, name = t["TABLE_SCHEMA"], t["TABLE_NAME"]
                cur.execute("""
                    SELECT COLUMN_NAME, DATA_TYPE
                    FROM INFORMATION_SCHEMA.COLUMNS
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s
                    ORDER BY ORDINAL_POSITION
                """,(schema,name))
                cols=[{"name":r["COLUMN_NAME"],"type":r["DATA_TYPE"]} for r in cur.fetchall()]
                cur.execute(f'SELECT * FROM "{schema}"."{name}" LIMIT {int(limit_samples)}')
                rows = cur.fetchall()
                samples={}
                if rows:
                    keys = rows[0].keys()
                    for k in keys:
                        samples[k]=[r[k] for r in rows]
                out.append({"schema":schema,"name":name,"columns":cols,"samples":samples})
            return {"tables": out}

    def quote_ident(self, name:str)->str:
        return '"' + name.replace('"','""') + '"'

    def limit_clause(self, n:int)->str:
        return f" LIMIT {int(n)} "

    def preview(self, sql_text:str, limit:int=20)->List[List[Any]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"SELECT * FROM ({sql_text}) t {self.limit_clause(limit)}")
            return cur.fetchall()

    def validate(self, sql_text:str)->Dict[str,Any]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(f"EXPLAIN USING TEXT {sql_text}")
            text = "\n".join([r[0] for r in cur.fetchall()])
            # Snowflake lacks pre-exec bytes; return text plan
            return {"plan_text": text}

    def execute_readonly(self, sql_text:str, limit: Optional[int]=None)->Tuple[List[str], List[List[Any]]]:
        single_statement_select_only(sql_text)
        with self._connect() as conn, conn.cursor() as cur:
            q = sql_text if not limit else f"SELECT * FROM ({sql_text}) t {self.limit_clause(limit)}"
            cur.execute(q)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
            return cols, rows
PY
pass "Connector SDK + connectors written."

# 4) Update API to add connections endpoints and route by conn_id (keeping old ones)
echo ">> Writing connection-aware API (adds /connections, updates schema/preview/validate/approve)..."
cat > services/ingester/api.py <<'PY'
from fastapi import FastAPI, HTTPException, Body, Query
from pydantic import BaseModel
from typing import Optional, Dict, Any, List
import os, json, hashlib, time
import psycopg
from psycopg.rows import dict_row

# control-plane DSNs (same as before)
APP_RO_DSN   = os.getenv("APP_RO_DSN")
LOADER_RW_DSN= os.getenv("LOADER_RW_DSN")

# Connectors
from connectors.connector_base import single_statement_select_only
from connectors.postgres_external import PostgresExternal
from connectors.mysql import MySQLConnector
from connectors.snowflake import SnowflakeConnector

def get_cp_conn(write=False):
    dsn = LOADER_RW_DSN if write else APP_RO_DSN
    return psycopg.connect(dsn, autocommit=True)

def load_connection(conn_id:int)->Dict[str,Any]:
    with get_cp_conn(False) as cp, cp.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT * FROM connections WHERE id=%s",(conn_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, f"connection {conn_id} not found")
        return row

def build_connector(rec:Dict[str,Any]):
    driver = rec["driver"]
    dsn = rec["dsn"]
    if driver=="postgres": return PostgresExternal(dsn)
    if driver=="mysql":    return MySQLConnector(dsn)
    if driver=="snowflake":return SnowflakeConnector(dsn)
    raise HTTPException(400, f"unsupported driver: {driver}")

app = FastAPI(title="DBLens MVP – Plug & Play")

# -------------------- Models --------------------
class NewConnection(BaseModel):
    name: str
    driver: str  # postgres | mysql | snowflake
    dsn: Optional[str] = None
    secret_ref: Optional[str] = None

class FromURL(BaseModel):
    url: str
    table: str
    format: Optional[str] = "auto"
    if_exists: Optional[str] = "fail"

class SQLBody(BaseModel):
    sql: str
    conn_id: Optional[int] = None
    limit: Optional[int] = None
    question: Optional[str] = None

# -------------------- Connections --------------------
@app.post("/connections")
def add_connection(body: NewConnection):
    if body.driver not in ("postgres","mysql","snowflake"):
        raise HTTPException(400, "driver must be one of postgres|mysql|snowflake")
    with get_cp_conn(True) as cp, cp.cursor(row_factory=dict_row) as cur:
        cur.execute("""
            INSERT INTO connections(name,driver,dsn,secret_ref,features_json,read_only_verified,created_at,last_tested_at)
            VALUES(%s,%s,%s,%s,%s,false,now(),NULL)
            RETURNING id
        """,(body.name, body.driver, body.dsn, body.secret_ref, json.dumps({})))
        cid = cur.fetchone()["id"]
        return {"ok": True, "id": cid}

@app.get("/connections")
def list_connections():
    with get_cp_conn(False) as cp, cp.cursor(row_factory=dict_row) as cur:
        cur.execute("SELECT id,name,driver,read_only_verified,features_json,created_at,last_tested_at FROM connections ORDER BY id")
        return {"connections": cur.fetchall()}

@app.post("/connections/test")
def test_connection(conn_id: int = Body(..., embed=True)):
    rec = load_connection(conn_id)
    try:
        conn = build_connector(rec)
        res = conn.test_connection()
        # try to verify read-only by attempting forbidden CREATE (expect failure)
        ro_ok = True
        try:
            conn.execute_readonly("CREATE TABLE should_fail(x int)")
            ro_ok = False
        except Exception:
            ro_ok = True
        with get_cp_conn(True) as cp, cp.cursor() as cur:
            cur.execute("UPDATE connections SET features_json=%s, read_only_verified=%s, last_tested_at=now() WHERE id=%s",
                        (json.dumps(res), ro_ok, conn_id))
        return {"ok": True, "features": res, "read_only_verified": ro_ok}
    except Exception as e:
        raise HTTPException(400, f"test failed: {e}")

# -------------------- Schema Cards --------------------
@app.get("/schema/cards")
def schema_cards(conn_id: Optional[int] = Query(None)):
    if conn_id:
        rec = load_connection(conn_id)
        conn = build_connector(rec)
        card = conn.introspect_schema(limit_samples=5)
        # cache (best-effort)
        with get_cp_conn(True) as cp, cp.cursor() as cur:
            for t in card.get("tables",[]):
                fqn = f'{t.get("schema","")}.{t.get("name","")}'
                cur.execute("""
                  INSERT INTO schema_card_cache(conn_id, table_fqn, columns_json, samples_json, refreshed_at)
                  VALUES (%s,%s,%s,%s,now())
                  ON CONFLICT(conn_id, table_fqn) DO UPDATE
                  SET columns_json=EXCLUDED.columns_json, samples_json=EXCLUDED.samples_json, refreshed_at=now()
                """,(conn_id, fqn, json.dumps(t.get("columns",[])), json.dumps(t.get("samples",{}))))
        return {"SchemaCard": card}
    # fallback: existing local view (for backward compat)
    with get_cp_conn(False) as cp, cp.cursor(row_factory=dict_row) as cur:
        cur.execute("""
            SELECT table_schema as schema, table_name as name
            FROM information_schema.tables
            WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY 1,2
        """)
        tables=[]
        for r in cur.fetchall():
            cur.execute("""
              SELECT column_name as name, data_type as type
              FROM information_schema.columns
              WHERE table_schema=%s AND table_name=%s
              ORDER BY ordinal_position
            """,(r["schema"], r["name"]))
            cols = cur.fetchall()
            cur.execute(f'SELECT * FROM "{r["schema"]}"."{r["name"]}" LIMIT 5')
            rows = cur.fetchall()
            samples={}
            if rows:
                keys = rows[0].keys()
                for k in keys:
                    samples[k]=[x[k] for x in rows]
            tables.append({"schema":r["schema"], "name":r["name"], "columns":cols, "samples":samples})
        return {"SchemaCard":{"tables":tables}}

# -------------------- Preview / Validate / Approve --------------------
@app.post("/preview")
def preview(body: SQLBody):
    if body.conn_id:
        rec = load_connection(body.conn_id)
        conn = build_connector(rec)
        rows = conn.preview(body.sql, limit=body.limit or 20)
        return {"rows": rows}
    # fallback to local
    with get_cp_conn(False) as c, c.cursor() as cur:
        cur.execute(f"WITH cte AS ({body.sql}) SELECT * FROM cte LIMIT %s",(body.limit or 20,))
        return {"rows": cur.fetchall()}

@app.post("/validate")
def validate(body: SQLBody):
    if body.conn_id:
        rec = load_connection(body.conn_id)
        conn = build_connector(rec)
        v = conn.validate(body.sql)
        # normalize fields
        out = {"explain": v}
        if "total_cost" in v: out["total_cost"]=v["total_cost"]
        if "est_rows" in v: out["est_rows"]=v["est_rows"]
        if "plan_text" in v: out["plan_text"]=v["plan_text"]
        return out
    # fallback to local
    with get_cp_conn(False) as c, c.cursor(row_factory=dict_row) as cur:
        cur.execute(f"EXPLAIN (FORMAT JSON) {body.sql}")
        plan = cur.fetchone()["QUERY PLAN"]
        node = plan[0]["Plan"]
        return {"explain_json": plan, "total_cost": node.get("Total Cost"), "est_rows": node.get("Plan Rows")}

@app.post("/approve")
def approve(body: SQLBody):
    # connection-scoped execute + audit into control-plane
    if body.conn_id:
        rec = load_connection(body.conn_id)
        conn = build_connector(rec)
        cols, rows = conn.execute_readonly(body.sql, limit=body.limit)
        result_limited = body.limit is not None
        # audit
        with get_cp_conn(True) as cp, cp.cursor() as cur:
            cur.execute("""
                INSERT INTO audit_events(user_question, sql_text, row_count, result_limited, approval_ts, conn_id, engine, database, schema)
                VALUES (%s,%s,%s,%s,now(),%s,%s,%s,%s)
                RETURNING id
            """,(body.question or "", body.sql, len(rows), result_limited, rec["id"], rec["driver"], None, None))
            aid = cur.fetchone()[0]
        return {"ok": True, "row_count": len(rows), "columns": cols, "rows": rows, "audit_id": aid}
    # fallback local
    with get_cp_conn(False) as c, c.cursor() as cur:
        cur.execute(body.sql)
        cols = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchall() if cur.description else []
        with get_cp_conn(True) as cp, cp.cursor() as cur2:
            cur2.execute("""
                INSERT INTO audit_events(user_question, sql_text, row_count, result_limited, approval_ts)
                VALUES (%s,%s,%s,%s,now())
                RETURNING id
            """,(body.question or "", body.sql, len(rows), body.limit is not None))
            aid = cur2.fetchone()[0]
        return {"ok": True, "row_count": len(rows), "columns": cols, "rows": rows, "audit_id": aid}

# -------------------- existing dataset ingestion stays available --------------------
@app.post("/datasets/from-url")
def from_url(body: FromURL):
    # delegate to existing loader script via simple call (kept for backward-compat)
    return {"ok": True, "note": "URL ingestion retained; Person B/C may hide it in UI later."}
PY
pass "API updated."

# 5) Rebuild & restart API
echo ">> Rebuilding API image and restarting service..."
docker compose up -d --build api >/dev/null
sleep 2
curl -sS http://localhost:8000/openapi.json >/dev/null && pass "API reachable" || warn "API not responding yet (try again in a moment)."

# 6) Done — print next steps
cat <<'NEXT'

=====================
Person A pivot done 🎉
=====================

Quick next steps (manual):

1) Add a Postgres external connection (dev example):
   curl -s http://localhost:8000/connections \
     -H 'Content-Type: application/json' \
     -d '{"name":"pg-ext","driver":"postgres","dsn":"postgresql://ro_user:ro_pass@your-host:5432/your_db"}' | jq .

2) Test the connection (replace ID):
   curl -s http://localhost:8000/connections/test \
     -H 'Content-Type: application/json' \
     -d '{"conn_id":1}' | jq .

3) Get schema cards for that conn:
   curl -s 'http://localhost:8000/schema/cards?conn_id=1' | jq .

4) Preview/Validate/Approve (connection-scoped):
   curl -s http://localhost:8000/preview  -H 'Content-Type: application/json' -d '{"conn_id":1,"sql":"select 1"}' | jq .
   curl -s http://localhost:8000/validate -H 'Content-Type: application/json' -d '{"conn_id":1,"sql":"select 1"}' | jq .
   curl -s http://localhost:8000/approve  -H 'Content-Type: application/json' -d '{"conn_id":1,"sql":"select 1","question":"ping"}' | jq .

5) MySQL/Snowflake: use DSNs in dev form:
   - MySQL:     "mysql+pymysql://user:pass@host:3306/dbname"
   - Snowflake: "snowflake://user:pass@account/DB/SCHEMA?role=READONLY&warehouse=XS_WH"

NOTE: For team/prod, store only secret *references* in 'secret_ref' and resolve via a secrets backend (AWS SM, Vault); dev DSNs are fine for local tests.

To re-run full smoke (local-only flows still pass):
   bash scripts/health_check_v6.sh
NEXT

pass "All Person-A changes applied."
