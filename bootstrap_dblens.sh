#!/usr/bin/env bash
set -euo pipefail

# ===== Settings =====
PROJECT_NAME="${PROJECT_NAME:-dblens}"
PY_CMD="${PY_CMD:-python3.11}"  # fallback to python3 if 3.11 not present
API_PORT="${API_PORT:-8000}"
PG_PORT="${PG_PORT:-5432}"
ADMINER_PORT="${ADMINER_PORT:-8080}"

# ===== Helpers =====
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing required command: $1"; exit 1; }
}

echo "==> Checking prerequisites"
need git
need docker
need bash
need sed
need awk
need curl
need npm || { echo "❌ Missing npm (Node.js). Please install Node.js (>=18)."; exit 1; }
if ! command -v "$PY_CMD" >/dev/null 2>&1; then
  echo "⚠️  $PY_CMD not found; falling back to python3"
  PY_CMD="python3"
fi

echo "==> Creating project at ./${PROJECT_NAME}"
mkdir -p "${PROJECT_NAME}"
cd "${PROJECT_NAME}"

# ----- Git / root layout -----
if [ ! -d .git ]; then
  git init -q
fi

mkdir -p backend/app/{routers,services,core,agents,validators} \
         backend/tests \
         eval/{scripts,data} \
         prompts \
         ui \
         infra/{docker,sql} \
         logs

# ----- .gitignore -----
cat > .gitignore <<'GIT'
# Python
__pycache__/
.venv/
*.pyc
.env
# Node
ui/node_modules/
ui/dist/
# Data & logs
eval/data/
logs/
# OS
.DS_Store
GIT

# ----- Python venv -----
if [ ! -d .venv ]; then
  echo "==> Creating Python venv"
  "$PY_CMD" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip >/dev/null

echo "==> Installing Python deps"
pip install fastapi "uvicorn[standard]" pydantic psycopg[binary] sqlglot duckdb \
            tenacity python-dotenv httpx orjson loguru mypy ruff black pre-commit \
            tqdm pandas requests pytest >/dev/null

# ----- Pre-commit -----
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
  hooks: [{id: mypy, additional_dependencies: [pydantic]}]
YAML
pre-commit install >/dev/null

# ----- Makefile -----
cat > Makefile <<'MAKE'
PY=python
ACT=source .venv/bin/activate
run-api:
	$(ACT); uvicorn backend.app.main:app --reload --port 8000
lint:
	$(ACT); ruff check . && black --check . && mypy backend || true
fmt:
	$(ACT); ruff check --fix .; black .
db-up:
	docker compose -f infra/docker/compose.yml up -d
db-down:
	docker compose -f infra/docker/compose.yml down -v
test:
	$(ACT); PYTHONPATH=. pytest -q
MAKE

# ----- Docker Compose (Postgres + Adminer) -----
cat > infra/docker/compose.yml <<YAML
services:
  pg:
    image: postgres:16
    container_name: ${PROJECT_NAME}_pg
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: demo
    ports: ["${PG_PORT}:5432"]
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./../sql/init:/docker-entrypoint-initdb.d
  adminer:
    image: adminer
    container_name: ${PROJECT_NAME}_adminer
    ports: ["${ADMINER_PORT}:8080"]
volumes:
  pgdata:
YAML

mkdir -p infra/sql/init

cat > infra/sql/init/00_readonly.sql <<'SQL'
-- Read-only role and permissions
CREATE ROLE dblens_ro LOGIN PASSWORD 'dblens_ro_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
REVOKE ALL ON DATABASE demo FROM PUBLIC;
GRANT CONNECT ON DATABASE demo TO dblens_ro;
GRANT USAGE ON SCHEMA public TO dblens_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dblens_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dblens_ro;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM dblens_ro;
SQL

cat > infra/sql/init/01_demo.sql <<'SQL'
-- Tiny demo table so the pipeline has something to read
CREATE TABLE IF NOT EXISTS items(
  id serial PRIMARY KEY,
  name text,
  price numeric
);
INSERT INTO items(name, price)
VALUES ('apple',1.2),('banana',0.8),('carrot',0.5)
ON CONFLICT DO NOTHING;
SQL

# ----- Backend files -----
touch backend/__init__.py backend/app/__init__.py \
      backend/app/routers/__init__.py backend/app/services/__init__.py \
      backend/app/core/__init__.py backend/app/agents/__init__.py \
      backend/app/validators/__init__.py

cat > backend/app/core/settings.py <<'PY'
from pydantic import BaseSettings

class Settings(BaseSettings):
    PG_HOST: str = "localhost"
    PG_PORT: int = 5432
    PG_DB: str = "demo"
    PG_USER: str = "dblens_ro"
    PG_PASSWORD: str = "dblens_ro_pw"

settings = Settings(_env_file=".env", _env_file_encoding="utf-8")
PY

cat > backend/app/core/logging.py <<'PY'
from loguru import logger
import os

def init_logging():
    os.makedirs("logs", exist_ok=True)
    logger.remove()
    logger.add(
        "logs/dblens.jsonl",
        format="{message}",
        serialize=True,
        enqueue=True,
        rotation="10 MB",
        retention="7 days",
        backtrace=False,
        diagnose=False,
        level="INFO",
    )
PY

cat > backend/app/agents/sdk.py <<'PY'
from typing import List, Dict, Any
import psycopg
import os

class DBAgent:
    def __init__(self):
        self._conn = psycopg.connect(
            host=os.getenv("PG_HOST","localhost"),
            port=int(os.getenv("PG_PORT","5432")),
            dbname=os.getenv("PG_DB","demo"),
            user=os.getenv("PG_USER","dblens_ro"),
            password=os.getenv("PG_PASSWORD","dblens_ro_pw"),
            autocommit=True,
        )

    def list_schemas(self) -> List[str]:
        with self._conn.cursor() as cur:
            cur.execute("select schema_name from information_schema.schemata;")
            return [r[0] for r in cur.fetchall()]

    def describe(self, table: str) -> List[Dict[str, Any]]:
        with self._conn.cursor() as cur:
            cur.execute("""
                select column_name, data_type, is_nullable
                from information_schema.columns
                where table_name = %s
                order by ordinal_position;
            """, (table,))
            cols = cur.fetchall()
        return [{"column": c[0], "type": c[1], "nullable": c[2]} for c in cols]

    def explain(self, sql: str) -> Dict[str, Any]:
        with self._conn.cursor() as cur:
            cur.execute("EXPLAIN (FORMAT JSON) " + sql)
            plan = cur.fetchone()[0][0]
        return plan

    def sample(self, sql: str, limit: int = 100):
        sql_lower = sql.lower()
        sql_limited = sql if " limit " in sql_lower else f"SELECT * FROM ({sql}) t LIMIT {limit}"
        with self._conn.cursor() as cur:
            cur.execute(sql_limited)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
        return {"columns": cols, "rows": rows}

    def execute_readonly(self, sql: str):
        return self.sample(sql, limit=1000)
PY

cat > backend/app/validators/safety.py <<'PY'
import re
import sqlglot

FORBIDDEN = r"\\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE)\\b"

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
        if est is None:
            # fallback: ok if we can't read the estimate
            return True
        return int(est) <= max_rows
    except Exception:
        return False
PY

cat > backend/app/services/pipeline.py <<'PY'
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import is_safe_select, explain_cost_ok
from loguru import logger

db = DBAgent()

def ask_plan_approve(question: str):
    # TEMP planner: replace with LLM later
    candidate_sqls = [f"SELECT 1 AS answer /* {question} */"]

    audited = []
    for sql in candidate_sqls:
        safe = is_safe_select(sql)
        cost_ok = explain_cost_ok(db, sql) if safe else False
        audited.append({"sql": sql, "safe": safe, "cost_ok": cost_ok})

    top = next((c for c in audited if c["safe"] and c["cost_ok"]), audited[0])
    preview = db.sample(top["sql"], limit=100) if top["safe"] else {"columns": [], "rows": []}
    logger.bind(event="ask", q=question, audited=audited).info("pipeline")
    return {"question": question, "candidates": audited, "preview": preview}
PY

cat > backend/app/routers/ask.py <<'PY'
from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.services.pipeline import ask_plan_approve

router = APIRouter()

class AskRequest(BaseModel):
    question: str

@router.post("/ask")
def ask(req: AskRequest):
    return ask_plan_approve(req.question)
PY

cat > backend/app/main.py <<'PY'
from fastapi import FastAPI
from backend.app.core.logging import init_logging
from backend.app.routers import ask

init_logging()
app = FastAPI(title="DBLens")
app.include_router(ask.router, prefix="/v1")
PY

# ----- .env -----
cat > .env <<'ENV'
PG_HOST=localhost
PG_PORT=5432
PG_DB=demo
PG_USER=dblens_ro
PG_PASSWORD=dblens_ro_pw
ENV

# ----- Eval smoke script -----
cat > eval/scripts/run_smoke.py <<'PY'
import time, json, requests

SMOKES = [
  "How many rows are in the items table?",
  "List 2 cheapest items."
]

for q in SMOKES:
    t0 = time.time()
    r = requests.post("http://localhost:8000/v1/ask", json={"question": q}, timeout=30)
    dt = time.time() - t0
    print(json.dumps({"q": q, "latency_s": round(dt,3), "status": r.status_code}))
    if r.ok:
        print(json.dumps(r.json(), indent=2))
PY

# ----- UI (Vite React TS) -----
if [ ! -f ui/package.json ]; then
  echo "==> Bootstrapping UI"
  ( cd ui && npm create vite@latest . -- --template react-ts >/dev/null )
  ( cd ui && npm i >/dev/null && npm i axios >/dev/null )
fi

# Overwrite App.tsx with our minimal wire
cat > ui/src/App.tsx <<'TSX'
import { useState } from "react";
import axios from "axios";

export default function App() {
  const [q, setQ] = useState("");
  const [resp, setResp] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const ask = async () => {
    setLoading(true);
    try {
      const r = await axios.post("http://localhost:8000/v1/ask", { question: q });
      setResp(r.data);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ padding: 24, fontFamily: "ui-sans-serif, system-ui" }}>
      <h1>DBLens MVP</h1>
      <div style={{ display: "flex", gap: 8 }}>
        <input
          style={{ flex: 1, padding: 8 }}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Ask a question…"
        />
        <button onClick={ask} disabled={!q || loading}>
          {loading ? "Running…" : "Ask"}
        </button>
      </div>

      {resp && (
        <div style={{ marginTop: 16 }}>
          <h3>Candidates</h3>
          <pre>{JSON.stringify(resp.candidates, null, 2)}</pre>
          <h3>Preview</h3>
          <pre>{JSON.stringify(resp.preview, null, 2)}</pre>
        </div>
      )}
    </div>
  );
}
TSX

# ----- Git first commit -----
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add .
  git commit -m "chore: bootstrap DBLens skeleton" >/dev/null || true
fi

# ----- Bring up Postgres -----
echo "==> Starting Postgres + Adminer (docker compose)"
docker compose -f infra/docker/compose.yml up -d

echo
echo "✅ Bootstrap complete."

cat <<MSG

Next steps:

1) Start the API:
   source .venv/bin/activate
   make run-api
   → Open http://localhost:${API_PORT}/docs

2) Start the UI (new terminal):
   cd ${PWD}/ui
   npm run dev
   → Vite will print a local URL (usually http://localhost:5173)

3) Run smoke test (with API running):
   source .venv/bin/activate
   python eval/scripts/run_smoke.py

Adminer (DB UI): http://localhost:${ADMINER_PORT}
   Server: localhost
   Username: app  Password: app  Database: demo

Housekeeping:
- make db-down   # stop & remove PG volumes
- make lint      # run ruff/black/mypy
- make fmt       # auto-fix

Happy building! 🚀
MSG
