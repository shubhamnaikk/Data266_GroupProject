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
            cur.execute("SET LOCAL statement_timeout = 5000")
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
