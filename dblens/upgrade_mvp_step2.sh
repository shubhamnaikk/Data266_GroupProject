#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
require() { [ -f "$1" ] || { echo "❌ Expected file not found: $1 (run from repo root: dblens/)"; exit 1; }; }

# sanity: are we at repo root?
require backend/app/main.py
require infra/docker/compose.yml

echo "==> Installing Python deps"
source .venv/bin/activate
pip install -U pydantic-settings openai tiktoken types-requests >/dev/null

echo "==> Ensuring env vars"
touch .env
grep -q '^LLM_PROVIDER=' .env || echo 'LLM_PROVIDER=openai' >> .env
grep -q '^LLM_MODEL=' .env    || echo 'LLM_MODEL=gpt-4o-mini' >> .env
grep -q '^LLM_API_KEY=' .env  || echo 'LLM_API_KEY=' >> .env

echo "==> Updating pre-commit mypy deps"
cat > .pre-commit-config.yaml <<'YAML'
repos:
- repo: https://github.com/psf/black
  rev: 24.8.0
  hooks: [{id: black}]
- repo: https://github.com/astral-sh/ruff-pre-commit
  rev: v0.6.9
  hooks: [{id: ruff}, {id: ruff-format}]
- repo: https://github.com/pre-commit/mirrors-mypy
  rev: v1.11.2
  hooks:
    - id: mypy
      additional_dependencies:
        - pydantic
        - pydantic-settings
        - types-requests
YAML
pre-commit install >/dev/null

echo "==> Writing backend files (overwrites)"
mkdir -p backend/app/{rag,routers,agents,services,validators,core} backend/tests
touch backend/app/rag/__init__.py backend/app/routers/__init__.py

# settings.py (pydantic v2)
cat > backend/app/core/settings.py <<'PY'
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    PG_HOST: str = "localhost"
    PG_PORT: int = 5432
    PG_DB: str = "demo"
    PG_USER: str = "dblens_ro"
    PG_PASSWORD: str = "dblens_ro_pw"
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

settings = Settings()
PY

# validators/safety.py
cat > backend/app/validators/safety.py <<'PY'
import re
import sqlglot

FORBIDDEN = r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE)\b"

def is_safe_select(sql: str) -> bool:
    if re.search(FORBIDDEN, sql, re.IGNORECASE):
        return False
    try:
        parsed = sqlglot.parse_one(sql)
        return bool(parsed) and parsed.key.upper() == "SELECT"
    except Exception:
        return False

def explain_cost_ok(db, sql: str, max_rows: int = 1_000_000) -> bool:
    try:
        plan = db.explain(sql)
        est = plan.get("Plan", {}).get("Plan Rows")
        return True if est is None else int(est) <= max_rows
    except Exception:
        return False

def add_preview_limit(sql: str, default_limit: int = 100) -> str:
    low = sql.lower()
    if " limit " in low:
        return sql
    return f"SELECT * FROM ({sql}) t LIMIT {default_limit}"
PY

# RAG: schema cards
cat > backend/app/rag/schema_cards.py <<'PY'
from typing import Dict, List
from backend.app.agents.sdk import DBAgent

def build_schema_cards() -> List[Dict]:
    db = DBAgent()
    with db._conn.cursor() as cur:  # type: ignore[attr-defined]
        cur.execute("""
          select table_name
          from information_schema.tables
          where table_schema='public' and table_type='BASE TABLE'
          order by table_name
        """)
        tables = [r[0] for r in cur.fetchall()]
    cards = []
    for t in tables:
        cols = db.describe(t)
        card = {
            "table": t,
            "purpose": f"Table {t} with columns " + ", ".join(c["column"] for c in cols),
            "columns": cols,
            "example_queries": [f"SELECT * FROM {t} LIMIT 5", f"SELECT COUNT(*) FROM {t}"],
        }
        cards.append(card)
    return cards
PY

# RAG: retriever
cat > backend/app/rag/retriever.py <<'PY'
from typing import List, Dict

def retrieve_schema_cards(question: str, cards: List[Dict], k: int = 3) -> List[Dict]:
    q_tokens = set(question.lower().split())
    def score(card: Dict) -> int:
        text = (card["table"] + " " + " ".join(c["column"] for c in card["columns"])).lower()
        toks = set(text.split())
        return len(q_tokens & toks)
    return sorted(cards, key=score, reverse=True)[:k]
PY

# LLM client
cat > backend/app/agents/llm.py <<'PY'
import os
from typing import List, Dict, Optional

class LLMClient:
    def __init__(self):
        self.provider = os.getenv("LLM_PROVIDER", "openai")
        self.model = os.getenv("LLM_MODEL", "gpt-4o-mini")
        self.api_key = os.getenv("LLM_API_KEY")

    def chat(self, messages: List[Dict[str, str]], n: int = 1, stop: Optional[List[str]] = None) -> List[str]:
        if not self.api_key:
            return ["SELECT 1 /* fallback */"]
        if self.provider == "openai":
            from openai import OpenAI
            client = OpenAI(api_key=self.api_key)
            resp = client.chat.completions.create(
                model=self.model, messages=messages, n=n, stop=stop, temperature=0.2
            )
            return [c.message.content or "" for c in resp.choices]
        raise NotImplementedError(f"Unsupported provider {self.provider}")
PY

# SQL generation (3 candidates)
cat > backend/app/agents/sqlgen.py <<'PY'
import re
from typing import List, Dict
from backend.app.agents.llm import LLMClient

PROMPT_SYS = """You translate questions into safe, efficient PostgreSQL SELECT queries.
Rules:
- SELECT-only (no INSERT/UPDATE/DELETE/DDL).
- Prefer LIMIT 100 for previews.
- Use provided schema only.
Return only SQL, no explanation, no markdown fences.
"""

def _mk_user_prompt(question: str, schema_ctx: List[Dict]) -> str:
    parts = ["Question:", question, "\nSchema:"]
    for c in schema_ctx:
        cols = ", ".join(f"{x['column']}({x['type']})" for x in c["columns"])
        parts.append(f"- {c['table']}: {cols}")
    parts.append("\nExamples:")
    for c in schema_ctx:
        for ex in c["example_queries"][:1]:
            parts.append(f"- {ex}")
    return "\n".join(parts)

def generate_sql_candidates(question: str, schema_ctx: List[Dict], n: int = 3) -> List[str]:
    llm = LLMClient()
    user = _mk_user_prompt(question, schema_ctx)
    outs = llm.chat([{"role": "system", "content": PROMPT_SYS},
                     {"role": "user", "content": user}], n=n)
    cleaned = []
    for o in outs:
        m = re.search(r"```sql(.*?)```", o, flags=re.S|re.I)
        sql = m.group(1).strip() if m else o.strip()
        cleaned.append(sql)
    uniq, seen = [], set()
    for s in cleaned:
        if s not in seen:
            seen.add(s); uniq.append(s)
    return uniq
PY

# pipeline (RAG->LLM->validate->preview)
cat > backend/app/services/pipeline.py <<'PY'
from typing import TypedDict, List, cast
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import is_safe_select, explain_cost_ok, add_preview_limit
from backend.app.agents.sqlgen import generate_sql_candidates
from backend.app.rag.schema_cards import build_schema_cards
from backend.app.rag.retriever import retrieve_schema_cards
from loguru import logger

class Candidate(TypedDict):
    sql: str
    safe: bool
    cost_ok: bool

db = DBAgent()
_SCHEMA_CARDS = build_schema_cards()

def ask_plan_approve(question: str):
    ctx = retrieve_schema_cards(question, _SCHEMA_CARDS, k=3)
    candidate_sqls = generate_sql_candidates(question, ctx, n=3)

    audited: List[Candidate] = []
    for sql in candidate_sqls:
        safe = is_safe_select(sql)
        cost_ok = explain_cost_ok(db, sql) if safe else False
        audited.append({"sql": sql, "safe": safe, "cost_ok": cost_ok})

    top = next((c for c in audited if c["safe"] and c["cost_ok"]), audited[0] if audited else {"sql":"SELECT 1","safe":True,"cost_ok":True})
    sql_for_preview = cast(str, top["sql"])
    preview_sql = add_preview_limit(sql_for_preview, 100) if top["safe"] else "SELECT 1"
    preview = db.sample(preview_sql, limit=100) if top["safe"] else {"columns": [], "rows": []}

    logger.bind(event="ask", q=question, audited=audited, ctx=[c["table"] for c in ctx]).info("pipeline")
    return {"question": question, "context_tables": [c["table"] for c in ctx], "candidates": audited, "preview": preview}
PY

# approve router
cat > backend/app/routers/approve.py <<'PY'
from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import is_safe_select

router = APIRouter()
db = DBAgent()

class ApproveRequest(BaseModel):
    sql: str

@router.post("/approve")
def approve(req: ApproveRequest):
    if not is_safe_select(req.sql):
        return {"ok": False, "error": "Unsafe SQL blocked"}
    res = db.execute_readonly(req.sql)
    return {"ok": True, "result": res}
PY

# main.py with CORS + approve router
cat > backend/app/main.py <<'PY'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from backend.app.core.logging import init_logging
from backend.app.routers import ask
from backend.app.routers import approve

init_logging()
app = FastAPI(title="DBLens")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ask.router, prefix="/v1")
app.include_router(approve.router, prefix="/v1")
PY

echo "==> Writing tests & eval"
cat > backend/tests/test_safety.py <<'PY'
from backend.app.validators.safety import is_safe_select, add_preview_limit

def test_blocks_writes():
    assert is_safe_select("INSERT INTO t VALUES (1)") is False
    assert is_safe_select("DROP TABLE x") is False

def test_allows_select():
    assert is_safe_select("SELECT * FROM items") is True

def test_adds_limit():
    s = add_preview_limit("SELECT * FROM items")
    assert "limit" in s.lower()
PY

mkdir -p eval/scripts
cat > eval/scripts/run_eval_toy.py <<'PY'
import time, json, requests, statistics as stats

QS = [
  "Show 5 rows from items",
  "How many rows are in items?",
  "List items with price < 1",
]

def ask(q):
    t0=time.time()
    r=requests.post("http://localhost:8000/v1/ask", json={"question": q}, timeout=45)
    dt=time.time()-t0
    j=r.json()
    ok_any = any(c["safe"] and c["cost_ok"] for c in j["candidates"])
    return dt, ok_any, j

latencies=[]; oks=0
for q in QS:
    dt, ok, j = ask(q)
    latencies.append(dt); oks += int(ok)
    print(json.dumps({"q":q,"latency_s":round(dt,2),"has_safe":ok}, indent=2))
print("p50 latency:", round(stats.median(latencies), 2), "s; valid-SQL rate:", f"{100*oks/len(QS):.0f}%")
PY

echo "==> Updating UI App.tsx (uses fetch; no axios needed)"
require ui/src/App.tsx || true
cat > ui/src/App.tsx <<'TSX'
import { useState } from "react";

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [result, setResult] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const ask = async () => {
    setLoading(true); setResult(null);
    const r = await fetch("http://localhost:8000/v1/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: q }),
    });
    setResp(await r.json());
    setLoading(false);
  };

  const approve = async (sql: string) => {
    const r = await fetch("http://localhost:8000/v1/approve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sql }),
    });
    setResult(await r.json());
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif,system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input style={{ flex: 1, padding: 8 }} value={q} onChange={(e)=>setQ(e.target.value)} placeholder="Ask a question…" />
        <button onClick={ask} disabled={!q || loading}>{loading ? "Thinking…" : "Ask"}</button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Context tables</h3>
          <pre>{JSON.stringify(resp.context_tables, null, 2)}</pre>

          <h3>Candidate SQLs</h3>
          {resp.candidates.map((c: any, i: number) => (
            <div key={i} style={{ border: "1px solid #ddd", padding: 8, margin: "8px 0" }}>
              <code>{c.sql}</code>
              <div>safe: {String(c.safe)} | cost_ok: {String(c.cost_ok)}</div>
              <button onClick={()=>approve(c.sql)} disabled={!c.safe || !c.cost_ok}>Approve & Run</button>
            </div>
          ))}

          <h3>Preview (top passing)</h3>
          <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
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

echo "==> Done. Next commands printed below."
cat <<'CMD'

# --- Run everything ---

# 1) Start DB if not running
make db-up

# 2) Start API (new terminal/tab is fine)
source .venv/bin/activate
make run-api

# 3) Start UI
cd ui
npm run dev

# 4) Quick toy eval (with API running)
cd ..
python eval/scripts/run_eval_toy.py

# 5) Tests & lint
pytest -q
make lint

# If you set LLM_API_KEY in .env, the pipeline will use the model;
# if empty, it falls back to a simple "SELECT 1" candidate.
CMD
