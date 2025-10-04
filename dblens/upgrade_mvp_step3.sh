#!/usr/bin/env bash
set -euo pipefail

# 1) Constrained decoding / validation
mkdir -p backend/app/validators
cat > backend/app/validators/constrain.py <<'PY'
from typing import Tuple, Set
import sqlglot
from sqlglot import exp
from backend.app.validators.safety import normalize_sql, is_safe_select

BLOCKED_SCHEMAS = {"pg_catalog", "information_schema"}

def _refs(parsed: exp.Expression) -> Set[str]:
    names: Set[str] = set()
    for t in parsed.find_all(exp.Table):
        # table name without schema
        tbl = (t.this.name if hasattr(t.this, "name") else str(t.this)).lower()
        names.add(tbl)
    return names

def constrain_sql(sql: str, allowed_tables: Set[str]) -> Tuple[bool, str, str]:
    """
    Enforce: SELECT-only, no system schemas, tables must be from allowed_tables.
    Returns (ok, reason, fixed_sql).
    """
    fixed = normalize_sql(sql)
    if not is_safe_select(fixed):
        return False, "not_select_or_forbidden", fixed
    try:
        parsed = sqlglot.parse_one(fixed, read="postgres")
    except Exception as e:
        return False, f"parse_error:{type(e).__name__}", fixed

    # block system schemas
    for t in parsed.find_all(exp.Table):
        sch = (str(t.db) if t.db is not None else "").lower()
        if sch in BLOCKED_SCHEMAS:
            return False, "blocked_schema", fixed

    # whitelist tables from context
    refs = _refs(parsed)
    if allowed_tables:
        allowed = {a.lower() for a in allowed_tables}
        for r in refs:
            if r not in allowed:
                return False, f"unknown_table:{r}", fixed

    return True, "ok", fixed
PY

# 2) Self-repair loop
mkdir -p backend/app/services
cat > backend/app/services/self_repair.py <<'PY'
import re
from typing import Dict, List
from backend.app.agents.llm import LLMClient

_SYS = """You are a SQL fixer. Repair the provided PostgreSQL SELECT query to satisfy:
- Use only the provided schema tables/columns.
- Keep it SELECT-only.
- If a column is wrong, replace it with the closest valid one.
- Return ONLY the SQL (no commentary, no markdown)."""

def _schema_block(schema_ctx: List[Dict]) -> str:
    parts = []
    for c in schema_ctx:
        cols = ", ".join(f"{x['column']}({x['type']})" for x in c["columns"])
        parts.append(f"- {c['table']}: {cols}")
    return "\n".join(parts)

def repair_sql(question: str, schema_ctx: List[Dict], bad_sql: str, db_error: str) -> str:
    llm = LLMClient()
    user = (
        f"Question:\n{question}\n\n"
        f"Schema:\n{_schema_block(schema_ctx)}\n\n"
        f"Previous SQL:\n{bad_sql}\n\n"
        f"Database error:\n{db_error}\n\n"
        "Return a corrected SQL."
    )
    out = llm.chat([{"role": "system", "content": _SYS},
                    {"role": "user", "content": user}], n=1)[0]
    m = re.search(r"```sql(.*?)```", out, flags=re.S|re.I)
    return (m.group(1) if m else out).strip()
PY

# 3) Wire constraints + self-repair into the pipeline
python - <<'PY'
from pathlib import Path
p = Path("backend/app/services/pipeline.py")
s = p.read_text()
if "constrain_sql" not in s:
    s = s.replace(
        "from backend.app.validators.safety import is_safe_select, explain_cost_ok, add_preview_limit, normalize_sql",
        "from backend.app.validators.safety import is_safe_select, explain_cost_ok, add_preview_limit, normalize_sql\nfrom backend.app.validators.constrain import constrain_sql\nfrom backend.app.services.self_repair import repair_sql"
    )
    s = s.replace(
        "    audited: List[Candidate] = []",
        "    allowed = {c['table'] for c in ctx}\n\n    audited: List[Candidate] = []"
    )
    s = s.replace(
        "    for sql in candidate_sqls:",
        "    attempts_log = []\n    for sql in candidate_sqls:"
    )
    s = s.replace(
        "        safe = is_safe_select(sql)\n        cost_ok = explain_cost_ok(db, sql) if safe else False\n        audited.append({\"sql\": sql, \"safe\": safe, \"cost_ok\": cost_ok})",
        "        # hard constraints first\n        ok, reason, fixed = constrain_sql(sql, allowed)\n        sql = fixed\n        safe = ok and is_safe_select(sql)\n        cost_ok = explain_cost_ok(db, sql) if safe else False\n        audited.append({\"sql\": sql, \"safe\": safe, \"cost_ok\": cost_ok})\n        attempts_log.append({\"sql\": sql, \"reason\": reason})"
    )
    s = s.replace(
        "    preview = db.sample(preview_sql, limit=100) if top[\"safe\"] else {\"columns\": [], \"rows\": []}",
        "    preview = {\"columns\": [], \"rows\": []}\n    if top[\"safe\"]:\n        try:\n            preview = db.sample(preview_sql, limit=100)\n        except Exception as e:\n            # self-repair up to 2 times\n            err = str(e)\n            for _ in range(2):\n                fixed = repair_sql(question, ctx, sql_for_preview, err)\n                ok, reason, fixed = constrain_sql(fixed, allowed)\n                if not ok or not is_safe_select(fixed) or not explain_cost_ok(db, fixed):\n                    attempts_log.append({\"repair_sql\": fixed, \"reason\": reason})\n                    continue\n                try:\n                    preview_sql = add_preview_limit(fixed, 100)\n                    preview = db.sample(preview_sql, limit=100)\n                    audited.insert(0, {\"sql\": fixed, \"safe\": True, \"cost_ok\": True})\n                    break\n                except Exception as e2:\n                    err = str(e2)\n                    attempts_log.append({\"repair_error\": err})\n"
    )
    s = s.replace(
        "    logger.bind(event=\"ask\", q=question, audited=audited, ctx=[c[\"table\"] for c in ctx]).info(\"pipeline\")",
        "    logger.bind(event=\"ask\", q=question, audited=audited, attempts=attempts_log, ctx=[c[\"table\"] for c in ctx]).info(\"pipeline\")"
    )
    p.write_text(s)
    print("patched pipeline.py")
else:
    print("pipeline.py already patched")
PY

# 4) Tests for constraint behavior
mkdir -p backend/tests
cat > backend/tests/test_constrain.py <<'PY'
from backend.app.validators.constrain import constrain_sql

def test_blocks_system_schema():
    ok, reason, _ = constrain_sql("SELECT * FROM pg_catalog.pg_class", {"items"})
    assert not ok and reason == "blocked_schema"

def test_blocks_unknown_table():
    ok, reason, _ = constrain_sql("SELECT * FROM nope", {"items"})
    assert not ok and reason.startswith("unknown_table")

def test_allows_known_table_and_select():
    ok, reason, fixed = constrain_sql("SELECT * FROM items LIMIT 2;", {"items"})
    assert ok and reason == "ok"
    assert fixed.endswith("LIMIT 2")
PY

# 5) Mini metrics over a small suite
mkdir -p eval/data
cat > eval/data/demo_suite.csv <<'CSV'
question
Show 5 rows from items
How many rows are in items?
List items with price < 1
CSV

cat > eval/scripts/run_metrics.py <<'PY'
import csv, time, json, requests, statistics as stats

def run_suite(path="eval/data/demo_suite.csv"):
    rows = list(csv.DictReader(open(path)))
    latencies, ok_count = [], 0
    for r in rows:
        q = r["question"]
        t0 = time.time()
        resp = requests.post("http://localhost:8000/v1/ask", json={"question": q}, timeout=60)
        dt = time.time() - t0
        try:
            j = resp.json()
            has_safe = any(c.get("safe") and c.get("cost_ok") for c in j.get("candidates", []))
            latencies.append(dt); ok_count += int(has_safe)
            print(json.dumps({"q": q, "latency_s": round(dt,2), "has_safe": has_safe}, indent=2))
        except Exception:
            print(json.dumps({"q": q, "status": resp.status_code, "body_start": resp.text[:200]}, indent=2))
            latencies.append(dt)
    p50 = round(stats.median(latencies), 2)
    p95 = round(sorted(latencies)[max(0,int(len(latencies)*0.95)-1)], 2)
    rate = round(100*ok_count/len(rows))
    print(f"p50: {p50}s, p95: {p95}s, valid-SQL rate: {rate}%")

if __name__ == "__main__":
    run_suite()
PY

echo "✅ Step3 files written."
