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
