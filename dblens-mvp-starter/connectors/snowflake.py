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
