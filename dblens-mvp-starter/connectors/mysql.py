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
