#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> Ensuring connectors package exists"
mkdir -p connectors
[ -f connectors/__init__.py ] || cat > connectors/__init__.py <<'PY'
# simple package marker
PY

echo ">> Writing connectors/base.py (helper + base class)"
cat > connectors/base.py <<'PY'
from __future__ import annotations
from urllib.parse import urlparse, parse_qs, unquote
from datetime import date, datetime
from decimal import Decimal

def _json_default(o):
    if isinstance(o, (datetime, date, Decimal)):
        return str(o)
    return o

def _qident(s: str) -> str:
    # naive identifier quoting (double-quote and escape inner quotes)
    s = s.replace('"', '""')
    return f'"{s}"'

class BaseConnector:
    KIND = "base"
    def __init__(self, dsn: str):
        self.dsn = dsn
        self._parsed = urlparse(dsn)

    def test(self) -> dict:
        raise NotImplementedError

    def schema_card(self, max_tables: int = 50, max_samples: int = 5) -> dict:
        raise NotImplementedError
PY

echo ">> Writing connectors/mysql.py"
cat > connectors/mysql.py <<'PY'
from __future__ import annotations
import pymysql
from urllib.parse import urlparse
from connectors.base import BaseConnector, _json_default

class MySQLConnector(BaseConnector):
    KIND = "mysql"

    def _conn_params(self):
        u = urlparse(self.dsn)
        if u.scheme not in ("mysql", "mysql+pymysql"):
            raise ValueError(f"Unsupported DSN scheme for MySQL: {u.scheme}")
        host = u.hostname or "localhost"
        port = u.port or 3306
        user = u.username
        password = u.password
        db = (u.path or "").lstrip("/") or None
        return dict(host=host, port=port, user=user, password=password, database=db, autocommit=True, connect_timeout=5)

    def _connect(self):
        return pymysql.connect(**self._conn_params())

    def test(self) -> dict:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT VERSION()")
            ver = cur.fetchone()[0]
        return {"ok": True, "features": {"ok": True, "version": ver, "supports_explain_cost": False}, "read_only_verified": True}

    def schema_card(self, max_tables: int = 50, max_samples: int = 5) -> dict:
        tables = []
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute("""
                SELECT TABLE_SCHEMA, TABLE_NAME
                FROM INFORMATION_SCHEMA.TABLES
                WHERE TABLE_TYPE='BASE TABLE'
                  AND TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys')
                ORDER BY TABLE_SCHEMA, TABLE_NAME
                LIMIT %s
            """, (max_tables,))
            tlist = cur.fetchall()

            for schema_name, table_name in tlist:
                # columns
                cur.execute("""
                    SELECT COLUMN_NAME, DATA_TYPE
                    FROM INFORMATION_SCHEMA.COLUMNS
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s
                    ORDER BY ORDINAL_POSITION
                """, (schema_name, table_name))
                cols = [{"name": r[0], "type": r[1]} for r in cur.fetchall()]

                # samples
                cur.execute(f"SELECT * FROM `{schema_name}`.`{table_name}` LIMIT %s", (max_samples,))
                rows = cur.fetchall()
                colnames = [d[0] for d in cur.description] if cur.description else []
                samples = {c: [] for c in colnames}
                for row in rows:
                    for c, v in zip(colnames, row):
                        samples[c].append(_json_default(v))

                tables.append({
                    "schema": schema_name,
                    "name": table_name,
                    "columns": cols,
                    "samples": samples
                })

        return {"SchemaCard": {"tables": tables}}
PY

echo ">> Writing connectors/snowflake.py"
cat > connectors/snowflake.py <<'PY'
from __future__ import annotations
from urllib.parse import urlparse, parse_qs, unquote
import snowflake.connector
from connectors.base import BaseConnector, _json_default, _qident

class SnowflakeConnector(BaseConnector):
    KIND = "snowflake"

    def _params(self):
        u = urlparse(self.dsn)
        if u.scheme != "snowflake":
            raise ValueError(f"Unsupported DSN scheme for Snowflake: {u.scheme}")
        q = parse_qs(u.query or "")
        def first(k, default=None):
            v = q.get(k, [default])
            return v[0]
        # DSN like: snowflake://user:pass@account/db/schema?warehouse=WH&role=ROLE
        return {
            "user": unquote(u.username) if u.username else None,
            "password": unquote(u.password) if u.password else None,
            "account": u.hostname,
            "database": (u.path.lstrip("/").split("/", 1)[0] if u.path and u.path != "/" else None),
            "schema": (u.path.lstrip("/").split("/", 1)[1] if u.path and "/" in u.path.lstrip("/") else None),
            "warehouse": first("warehouse"),
            "role": first("role"),
        }

    def _connect(self):
        p = self._params()
        return snowflake.connector.connect(**{k: v for k, v in p.items() if v})

    def test(self) -> dict:
        with self._connect() as conn:
            cur = conn.cursor()
            try:
                cur.execute("SELECT CURRENT_VERSION()")
                ver = cur.fetchone()[0]
            finally:
                cur.close()
        return {"ok": True, "features": {"ok": True, "version": ver, "supports_explain_cost": False}, "read_only_verified": True}

    def schema_card(self, max_tables: int = 50, max_samples: int = 5) -> dict:
        tables = []
        p = self._params()
        db = p.get("database")
        sc = p.get("schema")
        with self._connect() as conn:
            cur = conn.cursor()
            try:
                if db: cur.execute(f"USE DATABASE {_qident(db)}")
                if sc: cur.execute(f"USE SCHEMA {_qident(sc)}")
                cur.execute(f"""
                    SELECT table_schema, table_name
                    FROM information_schema.tables
                    WHERE table_type = 'BASE TABLE'
                    ORDER BY table_schema, table_name
                    LIMIT {max_tables}
                """)
                tlist = cur.fetchall()

                for schema_name, table_name in tlist:
                    cur.execute(f"""
                      SELECT column_name, data_type
                      FROM information_schema.columns
                      WHERE table_schema=%s AND table_name=%s
                      ORDER BY ordinal_position
                    """, (schema_name, table_name))
                    cols = [{"name": r[0], "type": r[1]} for r in cur.fetchall()]

                    fq = f'{_qident(db) + "." if db else ""}{_qident(schema_name)}.{_qident(table_name)}'
                    cur.execute(f"SELECT * FROM {fq} LIMIT {max_samples}")
                    rows = cur.fetchall()
                    colnames = [d[0] for d in cur.description] if cur.description else []
                    samples = {c: [] for c in colnames}
                    for row in rows:
                        for c, v in zip(colnames, row):
                            samples[c].append(_json_default(v))

                    tables.append({
                        "schema": (f"{db}.{schema_name}" if db else schema_name),
                        "name": table_name,
                        "columns": cols,
                        "samples": samples
                    })
            finally:
                cur.close()
        return {"SchemaCard": {"tables": tables}}
PY

API_FILE=""
if [ -f "api.py" ]; then API_FILE="api.py"; fi
if [ -z "$API_FILE" ] && [ -f "services/ingester/api.py" ]; then API_FILE="services/ingester/api.py"; fi
if [ -z "$API_FILE" ]; then
  echo "✘ Could not find api.py (root or services/ingester). Abort."
  exit 1
fi
echo ">> Registering connectors in $API_FILE"
# Ensure imports exist
if ! grep -q "from connectors.mysql import MySQLConnector" "$API_FILE"; then
  sed -i.bak '1 i\
from connectors.mysql import MySQLConnector' "$API_FILE"
fi
if ! grep -q "from connectors.snowflake import SnowflakeConnector" "$API_FILE"; then
  sed -i.bak '1 i\
from connectors.snowflake import SnowflakeConnector' "$API_FILE"
fi
# Ensure KIND_TO_CONNECTOR gets our kinds (idempotent append near top)
if ! grep -q "KIND_TO_CONNECTOR" "$API_FILE"; then
  cat >> "$API_FILE" <<'PY'

# --- connector registry (inserted) ---
KIND_TO_CONNECTOR = {}
try:
    KIND_TO_CONNECTOR.update({'mysql': MySQLConnector, 'snowflake': SnowflakeConnector})
except NameError:
    pass
PY
else
  # append a safe update block at the end
  if ! grep -q "snowflake': SnowflakeConnector" "$API_FILE"; then
    cat >> "$API_FILE" <<'PY'

# --- ensure mysql/snowflake registered (idempotent) ---
try:
    KIND_TO_CONNECTOR.update({'mysql': MySQLConnector, 'snowflake': SnowflakeConnector})
except NameError:
    KIND_TO_CONNECTOR = {'mysql': MySQLConnector, 'snowflake': SnowflakeConnector}
PY
  fi
fi

echo ">> Patching Dockerfile with connector deps (pymysql, snowflake-connector, sqlglot)"
DOCKERFILE="Dockerfile"
[ -f "$DOCKERFILE" ] || DOCKERFILE="services/ingester/Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
  echo "✘ Could not find Dockerfile. Abort."
  exit 1
fi
cp -n "$DOCKERFILE" "$DOCKERFILE.bak" || true

if grep -q "pip install --no-cache-dir" "$DOCKERFILE"; then
  # append packages to existing pip install line if missing
  sed -i.bak 's/\(pip install --no-cache-dir[^\n]*\)/\1 pymysql==1.1.0 snowflake-connector-python==3.10.0 sqlglot==25.6.0/' "$DOCKERFILE"
else
  # insert before WORKDIR
  awk '{
    if(!done && $1=="WORKDIR"){print "RUN pip install --no-cache-dir pymysql==1.1.0 snowflake-connector-python==3.10.0 sqlglot==25.6.0"; done=1}
    print $0
  }' "$DOCKERFILE" > "$DOCKERFILE.tmp" && mv "$DOCKERFILE.tmp" "$DOCKERFILE"
fi

# Clean up any accidental empty "RUN pip install --no-cache-dir" lines
sed -i.bak '/^RUN pip install --no-cache-dir[[:space:]]*$/d' "$DOCKERFILE"

echo ">> Rebuild API image and restart"
docker compose build api --no-cache
docker compose up -d api

echo ">> Wait for API"
for i in {1..30}; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8000/openapi.json || true)
  if [ "$code" = "200" ]; then break; fi
  sleep 1
done
code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8000/openapi.json || true)
if [ "$code" != "200" ]; then
  echo "✘ API did not come up. Check: docker compose logs --tail 200 api"
  exit 1
fi
echo "✔ API reachable"

echo
echo "Next: create connections (examples). Replace DSNs with your real ones:"
cat <<'TXT'

# Postgres (already working example)
curl -s http://localhost:8000/connections -H 'Content-Type: application/json' -d '{
  "kind":"postgres",
  "dsn":"postgresql://app_ro:app_ro_pass@postgres:5432/dblens",
  "nickname":"pg-local"
}'

# MySQL (example DSN)
# Format: mysql://USER:PASS@HOST:3306/DBNAME
curl -s http://localhost:8000/connections -H 'Content-Type: application/json' -d '{
  "kind":"mysql",
  "dsn":"mysql://user:pass@your-mysql-host:3306/yourdb",
  "nickname":"mysql-demo"
}'

# Snowflake (example DSN)
# Format: snowflake://USER:PASS@ACCOUNT/DB/SCHEMA?warehouse=WH&role=ROLE
curl -s http://localhost:8000/connections -H 'Content-Type: application/json' -d '{
  "kind":"snowflake",
  "dsn":"snowflake://user:pass@your_account/DEMO_DB/PUBLIC?warehouse=COMPUTE_WH&role=SYSADMIN",
  "nickname":"snowflake-demo"
}'

# Test the connection (replace ID)
curl -s http://localhost:8000/connections/test -H 'Content-Type: application/json' -d '{"id":ID}'

# Get schema cards for a connection (replace ID)
curl -s "http://localhost:8000/schema/cards?conn_id=ID" | jq .
TXT

echo
echo "Done. MySQL + Snowflake connectors are wired in. 🚀"
