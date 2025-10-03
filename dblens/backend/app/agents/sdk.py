from typing import List, Dict, Any
import psycopg
import os
from backend.app.validators.safety import normalize_sql


class DBAgent:
    def __init__(self):
        self._conn = psycopg.connect(
            host=os.getenv("PG_HOST", "localhost"),
            port=int(os.getenv("PG_PORT", "5432")),
            dbname=os.getenv("PG_DB", "demo"),
            user=os.getenv("PG_USER", "dblens_ro"),
            password=os.getenv("PG_PASSWORD", "dblens_ro_pw"),
            autocommit=True,
        )

    def list_schemas(self) -> List[str]:
        with self._conn.cursor() as cur:
            cur.execute("select schema_name from information_schema.schemata;")
            return [r[0] for r in cur.fetchall()]

    def describe(self, table: str) -> List[Dict[str, Any]]:
        with self._conn.cursor() as cur:
            cur.execute(
                """
                select column_name, data_type, is_nullable
                from information_schema.columns
                where table_name = %s
                order by ordinal_position;
            """,
                (table,),
            )
            cols = cur.fetchall()
        return [{"column": c[0], "type": c[1], "nullable": c[2]} for c in cols]

    def explain(self, sql: str) -> Dict[str, Any]:
        sql = normalize_sql(sql)
        with self._conn.cursor() as cur:
            cur.execute("EXPLAIN (FORMAT JSON) " + sql)
            plan = cur.fetchone()[0][0]  # first item of JSON array
        return plan

    def sample(self, sql: str, limit: int = 100):
        sql = normalize_sql(sql)
        sql_lower = sql.lower()
        sql_limited = (
            sql if " limit " in sql_lower else f"SELECT * FROM ({sql}) t LIMIT {limit}"
        )
        with self._conn.cursor() as cur:
            cur.execute(sql_limited)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
        return {"columns": cols, "rows": rows}

    def execute_readonly(self, sql: str):
        sql = normalize_sql(sql)
        return self.sample(sql, limit=1000)
