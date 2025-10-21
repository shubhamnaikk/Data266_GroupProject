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
