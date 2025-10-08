from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import subprocess, json, os, re, hashlib
import psycopg

import dbtools  # local helpers

app = FastAPI(title="DBLens MVP API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class FromURL(BaseModel):
    url: str
    table: str
    format: str = "auto"
    if_exists: str = "fail"
    schema_name: str = "public"  # rename to avoid pydantic shadow warning

class SQL(BaseModel):
    sql: str
    limit: int | None = None

class ApproveBody(SQL):
    question: str | None = None
    max_rows: int = 1000

@app.post("/datasets/from-url")
def from_url(p: FromURL):
    cmd = [
        "python", "/app/load_from_url.py",
        "--url", p.url,
        "--table", p.table,
        "--format", p.format,
        "--schema", p.schema_name,
        "--if-exists", p.if_exists,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return {"ok": proc.returncode == 0, "stdout": proc.stdout[-8000:], "stderr": proc.stderr[-8000:]}

@app.get("/schema/cards")
def schema_cards():
    return {"SchemaCard": dbtools.schema_cards()}

def _walk(node, fn):
    if isinstance(node, dict):
        fn(node)
        for v in node.values():
            _walk(v, fn)
    elif isinstance(node, list):
        for v in node: _walk(v, fn)

def _tables_from_explain(explain_json):
    found = set()
    _walk(explain_json, lambda n: n.get("Relation Name") and found.add(n["Relation Name"]))
    return sorted(found)

def _cartesian_joins(explain_json):
    js = []
    def visit(n):
        nt = n.get("Node Type", "")
        if "Join" in nt:
            has_cond = any(k in n for k in ("Hash Cond","Merge Cond","Join Filter"))
            if not has_cond:
                js.append(nt)
    _walk(explain_json, visit)
    return js

def _has_seqscan(explain_json):
    hit = False
    def visit(n):
        nonlocal hit
        if n.get("Node Type") == "Seq Scan":
            hit = True
    _walk(explain_json, visit)
    return hit

def _safety_flags(sql_text: str, rep: dict):
    # thresholds from env with defaults
    thr = {
        "MAX_TOTAL_COST": float(os.environ.get("VALIDATE_MAX_TOTAL_COST", "1000000")),   # 1e6
        "MAX_EST_ROWS":   float(os.environ.get("VALIDATE_MAX_EST_ROWS",   "500000")),    # 5e5
        "MAX_WIDTH":      float(os.environ.get("VALIDATE_MAX_WIDTH",      "16384")),     # 16 KB/row
        "FORBID_CARTESIAN": os.environ.get("VALIDATE_FORBID_CARTESIAN", "1") in ("1","true","True"),
    }
    reasons, level = [], "ok"

    total_cost = rep.get("total_cost") or 0
    est_rows   = rep.get("est_rows") or 0
    width      = rep.get("plan_width") or 0
    plan_json  = rep.get("explain_json", [{}])[0]
    select_star = bool(re.search(r'^\s*select\s+\*', sql_text, flags=re.I|re.S))

    if total_cost > thr["MAX_TOTAL_COST"]:
        reasons.append(f"total_cost {total_cost} > {thr['MAX_TOTAL_COST']}")
        level = "block"
    if est_rows > thr["MAX_EST_ROWS"]:
        reasons.append(f"est_rows {est_rows} > {thr['MAX_EST_ROWS']}")
        level = "block"
    if width and width > thr["MAX_WIDTH"]:
        reasons.append(f"plan_width {width} > {thr['MAX_WIDTH']}")
        level = "warn" if level != "block" else level
    if select_star:
        reasons.append("query selects '*' (wide results risk)")
        level = "warn" if level != "block" else level
    if thr["FORBID_CARTESIAN"]:
        carts = _cartesian_joins(plan_json)
        if carts:
            reasons.append(f"possible cartesian join(s): {', '.join(carts)}")
            level = "block"

    metrics = {"total_cost": total_cost, "est_rows": est_rows, "plan_width": width, "select_star": select_star,
               "has_seqscan": _has_seqscan(plan_json)}
    return {"level": level, "reasons": reasons, "metrics": metrics, "thresholds": thr}

@app.post("/preview")
def preview(p: SQL):
    rows = dbtools.preview(p.sql, p.limit or 20)
    return {"rows": [list(r) for r in rows]}

@app.post("/validate")
def validate(p: SQL):
    rep = dbtools.explain(p.sql)
    flags = _safety_flags(p.sql, rep)
    rep["flags"] = flags
    return rep

@app.post("/approve")
def approve(p: ApproveBody):
    rep = dbtools.explain(p.sql)
    explain_json = rep.get("explain_json", [])
    dsn_app = os.environ.get("APP_RO_DSN")
    if not dsn_app: return {"ok": False, "error": "APP_RO_DSN not set"}
    with psycopg.connect(dsn_app) as conn:
        conn.execute("SET statement_timeout = '15000ms'")
        q = f"WITH cte AS ({p.sql}) SELECT * FROM cte LIMIT %s"
        rows = conn.execute(q, (p.max_rows,)).fetchall()
    json_rows = [list(r) for r in rows]
    preview_hash = hashlib.sha256(json.dumps(json_rows[:50], default=str).encode()).hexdigest()
    row_count = len(json_rows)

    tables = _tables_from_explain(explain_json)
    fq = [f"public.{t}" for t in tables]
    provenance = []
    dsn_loader = os.environ.get("LOADER_RW_DSN")
    if not dsn_loader: return {"ok": False, "error": "LOADER_RW_DSN not set"}
    with psycopg.connect(dsn_loader, autocommit=True) as conn:
        if fq:
            q = """
                SELECT DISTINCT ON (table_name)
                       table_name, url, sha256, row_count, bytes, created_at
                FROM ingestion_log
                WHERE table_name = ANY (%s)
                ORDER BY table_name, id DESC
            """
            for r in conn.execute(q, (fq,)).fetchall():
                provenance.append({
                    "table_name": r[0], "url": r[1], "sha256": r[2],
                    "row_count": r[3], "bytes": r[4],
                    "created_at": r[5].isoformat() if r[5] else None
                })
        conn.execute(
            """
            INSERT INTO audit_events
              (user_question, sql_text, explain_json, preview_hash, row_count, result_limited, schema_snapshot, url_provenance)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
            """,
            (p.question, p.sql, json.dumps(explain_json), preview_hash, row_count, True, None, json.dumps(provenance))
        )
    return {"ok": True, "tables": tables, "row_count": row_count, "result_limited": True,
            "preview_hash": preview_hash, "explain_total_cost": rep.get("total_cost"),
            "explain_est_rows": rep.get("est_rows"), "rows": json_rows, "provenance": provenance}
