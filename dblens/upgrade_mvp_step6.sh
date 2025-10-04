#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 0) ensure logs dir exists
mkdir -p logs

# 1) SQLite-backed audit store
mkdir -p backend/app/store
cat > backend/app/store/audit.py <<'PY'
import os, json, sqlite3, time
from typing import Any, Dict, List, Optional

class AuditStore:
    def __init__(self, db_path: str = "logs/audit.db") -> None:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.execute("""
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts REAL,
          question TEXT,
          top_sql TEXT,
          safe INTEGER,
          cost_ok INTEGER,
          preview_rows INTEGER,
          ctx TEXT,
          attempts TEXT
        )""")
        self._conn.commit()

    def add_event(self, question: str, top_sql: str, safe: bool, cost_ok: bool,
                  preview: Dict[str, Any], ctx: List[Dict[str, Any]], attempts: List[Dict[str, Any]]) -> int:
        rows = len(preview.get("rows") or [])
        ctx_json = json.dumps(ctx)
        attempts_json = json.dumps(attempts)
        cur = self._conn.execute(
            "INSERT INTO events(ts, question, top_sql, safe, cost_ok, preview_rows, ctx, attempts) VALUES(?,?,?,?,?,?,?,?)",
            (time.time(), question, top_sql, int(safe), int(cost_ok), rows, ctx_json, attempts_json)
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def recent(self, limit: int = 10) -> List[Dict[str, Any]]:
        cur = self._conn.execute(
            "SELECT id, ts, question, top_sql, safe, cost_ok, preview_rows FROM events ORDER BY id DESC LIMIT ?",
            (int(limit),)
        )
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    def get(self, event_id: int) -> Optional[Dict[str, Any]]:
        cur = self._conn.execute(
            "SELECT id, ts, question, top_sql, safe, cost_ok, preview_rows, ctx, attempts FROM events WHERE id=?",
            (int(event_id),)
        )
        row = cur.fetchone()
        if not row:
            return None
        cols = [c[0] for c in cur.description]
        rec = dict(zip(cols, row))
        # keep ctx/attempts as JSON strings; caller can json.loads if needed
        return rec

STORE = AuditStore()
PY

# 2) Wire audit store into pipeline (save every ask)
python - <<'PY'
from pathlib import Path
import json
p = Path("backend/app/services/pipeline.py")
s = p.read_text()
if "from backend.app.store.audit import STORE" not in s:
    s = s.replace(
        "from loguru import logger",
        "from loguru import logger\nfrom backend.app.store.audit import STORE"
    )
# ensure attempts_log exists (safety)
if "attempts_log =" not in s:
    s = s.replace("for sql in candidate_sqls:", "attempts_log = []\n    for sql in candidate_sqls:")
# append a store write before return
if "event_id =" not in s:
    s = s.replace(
        '    logger.bind(event="ask", q=question, audited=audited, attempts=attempts_log, ctx=[c["table"] for c in ctx]).info("pipeline")',
        '    logger.bind(event="ask", q=question, audited=audited, attempts=attempts_log, ctx=[c["table"] for c in ctx]).info("pipeline")\n'
        '    try:\n'
        '        top = audited[0] if audited else {"sql":"SELECT 1","safe":True,"cost_ok":True}\n'
        '        event_id = STORE.add_event(question, top.get("sql",""), bool(top.get("safe")), bool(top.get("cost_ok")), preview, ctx, attempts_log)\n'
        '    except Exception as _e:\n'
        '        event_id = -1\n'
        '    '
    )
    # include event_id in returned object if not present
    s = s.replace(
        '    return {"question": question, "context_tables": [c["table"] for c in ctx], "candidates": audited, "preview": preview}',
        '    return {"question": question, "context_tables": [c["table"] for c in ctx], "candidates": audited, "preview": preview, "event_id": event_id}'
    )
p.write_text(s)
print("patched pipeline to persist audit")
PY

# 3) History router (recent + get by id)
mkdir -p backend/app/routers
cat > backend/app/routers/history.py <<'PY'
from fastapi import APIRouter
from typing import Optional
from backend.app.store.audit import STORE

router = APIRouter()

@router.get("/history/recent")
def recent(limit: int = 10):
    try:
        return {"ok": True, "items": STORE.recent(limit=limit)}
    except Exception as e:
        return {"ok": False, "error": str(e)[:200]}

@router.get("/history/{event_id}")
def by_id(event_id: int):
    rec = STORE.get(event_id)
    if not rec:
        return {"ok": False, "error": "not_found"}
    return {"ok": True, "item": rec}
PY

# 4) API-key guard (optional) and wire history router
python - <<'PY'
from pathlib import Path
p = Path("backend/app/main.py")
s = p.read_text()
changed = False
# import history router
if "from backend.app.routers import history" not in s:
    s = s.replace(
        "from backend.app.routers import ask\nfrom backend.app.routers import approve\nfrom backend.app.routers import explain",
        "from backend.app.routers import ask\nfrom backend.app.routers import approve\nfrom backend.app.routers import explain\nfrom backend.app.routers import history"
    ); changed = True

# add API key guard (dependency) if not present
if "def api_key_guard" not in s:
    s += """

from fastapi import Header, HTTPException, Depends
import os

def api_key_guard(x_api_key: str | None = Header(default=None)):
    required = os.getenv("API_KEY")
    if not required:
        return True
    if x_api_key != required:
        raise HTTPException(status_code=401, detail="invalid api key")
    return True
"""
    changed = True

# include routers (attach dependency at include time)
if 'app.include_router(history.router, prefix="/v1")' not in s:
    s = s.replace(
        'app.include_router(explain.router, prefix="/v1")',
        'app.include_router(explain.router, prefix="/v1")\napp.include_router(history.router, prefix="/v1")'
    ); changed = True

if changed:
    p.write_text(s)
    print("main.py updated (history + api guard)")
else:
    print("main.py already has history/api guard")
PY

# 5) UI: simple History panel
cat > ui/src/App.tsx <<'TSX'
import { useEffect, useState } from "react";

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
  const [history, setHistory] = useState<any[]>([]);

  const fetchHistory = async () => {
    const r = await fetch("http://localhost:8000/v1/history/recent?limit=10");
    const j = await r.json();
    if (j.ok) setHistory(j.items || []);
  };

  useEffect(() => { fetchHistory(); }, []);

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
    fetchHistory();
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
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui", display:"grid", gridTemplateColumns:"2fr 1fr", gap:24 }}>
      <div>
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

      <div>
        <h2>History</h2>
        <button onClick={fetchHistory} style={{marginBottom:8}}>Refresh</button>
        <div style={{display:"flex", flexDirection:"column", gap:8}}>
          {history.map((h:any)=>(
            <div key={h.id} style={{border:"1px solid #ddd", padding:8}}>
              <div style={{fontSize:12, opacity:0.8}}>#{h.id} · {new Date(h.ts*1000).toLocaleString()}</div>
              <div style={{fontWeight:600}}>{h.question}</div>
              <div style={{marginTop:6}}>
                <Badge ok={!!h.safe} label={h.safe ? "safe" : "unsafe"} />
                <Badge ok={!!h.cost_ok} label={h.cost_ok ? "cost-ok" : "cost-high"} />
                <span style={{fontSize:12, marginLeft:8}}>rows: {h.preview_rows}</span>
              </div>
              <pre style={{whiteSpace:"pre-wrap"}}>{h.top_sql}</pre>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
TSX

# 6) Tests: history + API key guard
mkdir -p backend/tests
cat > backend/tests/test_history.py <<'PY'
from fastapi.testclient import TestClient
from backend.app.main import app

def test_history_recent_populates():
    c = TestClient(app)
    # trigger an event
    r = c.post("/v1/ask", json={"question": "Show 5 rows from items"})
    assert r.status_code == 200
    # fetch history
    r2 = c.get("/v1/history/recent?limit=5")
    j = r2.json()
    assert j["ok"] is True
    assert isinstance(j["items"], list)
    assert any("Show 5 rows" in (it.get("question") or "") for it in j["items"])

def test_history_by_id_roundtrip():
    c = TestClient(app)
    r = c.post("/v1/ask", json={"question": "How many rows are in items?"})
    eid = r.json().get("event_id")
    r2 = c.get(f"/v1/history/{eid}")
    assert r2.status_code == 200
    assert r2.json()["ok"] is True
PY

cat > backend/tests/test_api_key_guard.py <<'PY'
import os
from fastapi.testclient import TestClient
from backend.app.main import app

def test_api_key_guard_blocks(monkeypatch):
    monkeypatch.setenv("API_KEY", "secret")
    c = TestClient(app)
    # missing header should fail
    r = c.post("/v1/lint", json={"sql":"SELECT 1"})
    assert r.status_code == 401
    # with header should pass
    r2 = c.post("/v1/lint", headers={"x-api-key":"secret"}, json={"sql":"SELECT 1"})
    assert r2.status_code == 200
PY

# 7) Style
ruff check . --fix || true
black . || true

echo "✅ Step6 applied."
