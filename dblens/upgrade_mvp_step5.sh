#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# deps for cookbook
source .venv/bin/activate 2>/dev/null || true
python -m pip install -U pyyaml >/dev/null

# --- 1) /lint endpoint: safety+cost+plan summary (always JSON) ---
mkdir -p backend/app/routers
cat > backend/app/routers/lint.py <<'PY'
from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import (
    normalize_sql, is_safe_select, explain_cost_ok, summarize_plan
)

router = APIRouter()
db = DBAgent()

class LintRequest(BaseModel):
    sql: str

@router.post("/lint")
def lint(req: LintRequest):
    sql = normalize_sql(req.sql)
    safe = is_safe_select(sql)
    expl = None
    cost_ok = False
    if safe:
        try:
            expl = db.explain(sql)
            cost_ok = explain_cost_ok(db, sql)
        except Exception as e:
            return {"ok": False, "safe": safe, "cost_ok": False, "error": str(e)[:200]}
    return {
        "ok": True,
        "sql": sql,
        "safe": safe,
        "cost_ok": cost_ok,
        "plan_summary": summarize_plan(expl) if expl else None,
    }
PY

# wire router
python - <<'PY'
from pathlib import Path
p=Path("backend/app/main.py")
s=p.read_text()
if "from backend.app.routers import lint" not in s:
    s=s.replace("from backend.app.routers import ask\nfrom backend.app.routers import approve\nfrom backend.app.routers import explain",
                "from backend.app.routers import ask\nfrom backend.app.routers import approve\nfrom backend.app.routers import explain\nfrom backend.app.routers import lint")
    s=s.replace('app.include_router(explain.router, prefix="/v1")',
                'app.include_router(explain.router, prefix="/v1")\napp.include_router(lint.router, prefix="/v1")')
    p.write_text(s)
    print("wired /v1/lint")
else:
    print("/v1/lint already wired")
PY

# --- 2) Query cookbook: light templates as an extra candidate ---
mkdir -p backend/app/rag
cat > backend/app/rag/cookbook.yaml <<'YAML'
# super-simple starter cookbook of query patterns
patterns:
  - name: count_rows
    when_any: ["count", "how many", "number of rows"]
    sql: "SELECT COUNT(*) FROM {table}"
  - name: top_n_rows
    when_any: ["show", "list", "first", "top", "sample", "rows"]
    sql: "SELECT * FROM {table} LIMIT {n}"
    default_n: 5
  - name: price_filter_under
    when_any: ["price <", "under", "cheaper than", "below"]
    sql: "SELECT * FROM {table} WHERE price < {threshold} LIMIT 100"
    default_threshold: 1
YAML

cat > backend/app/rag/cookbook.py <<'PY'
import re
from typing import List, Dict, Optional
import yaml

def _pick_primary_table(ctx: List[Dict]) -> Optional[str]:
    return ctx[0]["table"] if ctx else None

def _extract_n(q: str) -> int:
    m = re.search(r"\b(\d+)\b", q)
    return int(m.group(1)) if m else 5

def _extract_threshold(q: str) -> float:
    m = re.search(r"(\d+(\.\d+)?)", q)
    return float(m.group(1)) if m else 1.0

def suggest_from_cookbook(question: str, ctx: List[Dict]) -> Optional[str]:
    try:
        spec = yaml.safe_load(open("backend/app/rag/cookbook.yaml"))
    except Exception:
        return None
    table = _pick_primary_table(ctx)
    if not table:
        return None
    q = question.lower()

    for p in spec.get("patterns", []):
        if any(kw in q for kw in (p.get("when_any") or [])):
            sql_tmpl = p["sql"]
            if "{n}" in sql_tmpl:
                n = p.get("default_n") or _extract_n(q)
                return sql_tmpl.format(table=table, n=n)
            if "{threshold}" in sql_tmpl:
                val = p.get("default_threshold") or _extract_threshold(q)
                return sql_tmpl.format(table=table, threshold=val)
            return sql_tmpl.format(table=table)
    return None
PY

# patch pipeline to include cookbook candidate (front of list)
python - <<'PY'
from pathlib import Path
p=Path("backend/app/services/pipeline.py")
s=p.read_text()
if "suggest_from_cookbook" not in s:
    s=s.replace(
        "from backend.app.agents.sqlgen import generate_sql_candidates",
        "from backend.app.agents.sqlgen import generate_sql_candidates\nfrom backend.app.rag.cookbook import suggest_from_cookbook"
    )
    s=s.replace(
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)\n    if not candidate_sqls:",
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)\n    # prepend cookbook suggestion if available\n    cb = suggest_from_cookbook(question, ctx)\n    if cb:\n        candidate_sqls = [cb] + candidate_sqls\n    if not candidate_sqls:"
    )
    Path("backend/app/services/pipeline.py").write_text(s)
    print("pipeline: cookbook wired")
else:
    print("pipeline already has cookbook import")
PY

# --- 3) UI: editable candidate, Lint + Approve Edited ---
cat > ui/src/App.tsx <<'TSX'
import { useState } from "react";

type Cand = { sql: string; safe: boolean; cost_ok: boolean };

function Badge({ok, label}:{ok:boolean; label:string}) {
  const bg = ok ? "#e7f8ed" : "#fde8e8";
  const col = ok ? "#127a3a" : "#a11d1d";
  return <span style={{background:bg,color:col,borderRadius:8,padding:"2px 8px",fontSize:12,marginRight:8}}>{label}</span>;
}

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [result, setResult] = useState<any>(null);
  const [plan, setPlan] = useState<any>(null);
  const [lint, setLint] = useState<any>(null);
  const [editSQL, setEditSQL] = useState<string>("");

  const ask = async () => {
    setResult(null); setPlan(null); setLint(null); setEditSQL("");
    const r = await fetch("http://localhost:8000/v1/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: q }),
    });
    const j = await r.json();
    setResp(j);
    if (j?.candidates?.[0]?.sql) setEditSQL(j.candidates[0].sql);
  };

  const approve = async (sql: string) => {
    const r = await fetch("http://localhost:8000/v1/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setResult(await r.json());
  };

  const explain = async (sql: string) => {
    setPlan(null);
    const r = await fetch("http://localhost:8000/v1/explain", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setPlan(await r.json());
  };

  const doLint = async () => {
    const r = await fetch("http://localhost:8000/v1/lint", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql: editSQL }),
    });
    setLint(await r.json());
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input style={{ flex: 1, padding: 8 }} value={q} onChange={(e)=>setQ(e.target.value)} placeholder="Ask a question…" />
        <button onClick={ask} disabled={!q}>Ask</button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Context tables</h3>
          <pre>{JSON.stringify(resp.context_tables, null, 2)}</pre>

          <h3>Candidate SQLs</h3>
          {resp.candidates.map((c: Cand, i: number) => (
            <div key={i} style={{ border: "1px solid #ddd", padding: 8, margin: "8px 0" }}>
              <code>{c.sql}</code>
              <div style={{marginTop:6}}>
                <Badge ok={c.safe} label={c.safe ? "safe" : "unsafe"} />
                <Badge ok={c.cost_ok} label={c.cost_ok ? "cost-ok" : "cost-high"} />
              </div>
              <div style={{display:"flex", gap:8, marginTop:8}}>
                <button onClick={()=>explain(c.sql)}>Explain</button>
                <button onClick={()=>approve(c.sql)} disabled={!c.safe || !c.cost_ok}>Approve & Run</button>
              </div>
            </div>
          ))}

          <h3>Edit & Lint</h3>
          <textarea
            value={editSQL}
            onChange={(e)=>setEditSQL(e.target.value)}
            rows={4}
            style={{width:"100%", fontFamily:"monospace", padding:8}}
            placeholder="Edit SQL here..."
          />
          <div style={{display:"flex", gap:8, marginTop:8}}>
            <button onClick={doLint}>Lint Edited</button>
            <button onClick={()=>approve(editSQL)}>Approve Edited</button>
          </div>
          {lint && (
            <div style={{marginTop:8}}>
              <Badge ok={!!lint.safe} label={lint.safe ? "safe" : "unsafe"} />
              <Badge ok={!!lint.cost_ok} label={lint.cost_ok ? "cost-ok" : "cost-high"} />
              <pre>{JSON.stringify(lint, null, 2)}</pre>
            </div>
          )}

          <h3>Preview (top passing)</h3>
          <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
        </div>
      )}

      {plan && (
        <div style={{ marginTop: 16 }}>
          <h3>Explain</h3>
          <pre>{JSON.stringify(plan, null, 2)}</pre>
        </div>
      )}

      {result && (
        <div style={{ marginTop: 16 }}>
          <h3>Full result</h3>
          <pre>{JSON.stringify(result, null, 2)}</pre>
        </div>
      )}
    </div>
  );
}
TSX

# --- 4) Tests (cookbook + lint happy paths) ---
mkdir -p backend/tests
cat > backend/tests/test_cookbook.py <<'PY'
from backend.app.rag.cookbook import suggest_from_cookbook

CTX = [{"table":"items", "columns":[{"column":"id","type":"int"},{"column":"name","type":"text"},{"column":"price","type":"numeric"}]}]

def test_cookbook_count():
    sql = suggest_from_cookbook("how many rows in items", CTX)
    assert sql and "count" in sql.lower() and "from items" in sql.lower()

def test_cookbook_topn():
    sql = suggest_from_cookbook("show 3 rows", CTX)
    assert sql and "limit 3" in sql.lower()

def test_cookbook_price_under():
    sql = suggest_from_cookbook("items under 2", CTX)
    assert sql and "price <" in sql.lower()
PY

cat > backend/tests/test_lint_endpoint.py <<'PY'
from fastapi.testclient import TestClient
from backend.app.main import app

client = TestClient(app)

def test_lint_ok():
    r = client.post("/v1/lint", json={"sql":"SELECT 1"})
    j = r.json()
    assert j["ok"] is True
    assert j["safe"] is True
PY

# --- 5) Style ---
ruff check . --fix || true
black . || true

echo "✅ Step5 applied."
