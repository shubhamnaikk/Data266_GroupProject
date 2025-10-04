#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
from pathlib import Path
import re

# --- Fix pipeline.py ---
pp = Path("backend/app/services/pipeline.py")
ps = pp.read_text()

# Use the SDK's list() instead of non-existent list_tables()
ps = ps.replace("db.list_tables()", "db.list()")

# Build schema for all tables (describe requires a table)
if "schema = {t: db.describe(t) for t in tables}" not in ps:
    # inject a minimal schema build right after db = DBAgent()
    ps = re.sub(
        r"(db\s*=\s*DBAgent\(\)\s*\n)",
        r"\1tables = db.list()\n"
        r"schema = {t: db.describe(t) for t in tables}\n",
        ps,
        count=1,
    )

# build_schema_cards should take only schema (remove extra args if present)
ps = ps.replace("build_schema_cards(schema, question)", "build_schema_cards(schema)")
ps = ps.replace("build_schema_cards(tables, schema)", "build_schema_cards(schema)")

# If code doesn't derive ctx elsewhere, ensure a minimal ctx exists
if "ctx =" not in ps:
    ps = re.sub(
        r"(schema\s*=\s*\{t:\s*db\.describe\(t\)\s*for\s*t\s*in\s*tables\}\s*\n)",
        r"\1ql = question.lower()\n"
        r"pick = [t for t in tables if t in ql] or tables[:1]\n"
        r'ctx = [{"table": t, "columns": schema[t]} for t in pick]\n',
        ps,
        count=1,
    )

# Clean up any previously assigned-but-unused ctx_tables
ps = re.sub(r"^\s*ctx_tables\s*=\s*\[.*\]\s*$", "", ps, flags=re.M)

pp.write_text(ps)
print("patched: pipeline.py")

# --- Fix audit.py ---
ap = Path("backend/app/store/audit.py")
asrc = ap.read_text()

# Safe computation of preview_rows (avoid Optional[Any] to len)
asrc = re.sub(
    r"preview_rows\s*=\s*len\([^)]+\)",
    (
        'rows = preview.get("rows") if isinstance(preview, dict) else []\n'
        "        rows = rows if isinstance(rows, list) else []\n"
        "        preview_rows = len(rows)"
    ),
    asrc,
)

# lastrowid may be Optional[int]
asrc = asrc.replace(
    "return int(cur.lastrowid)",
    "eid = cur.lastrowid or 0\n        return int(eid)"
)

# Ensure by_id exists (and avoid any old .get() usage downstream)
if "def by_id(" not in asrc:
    asrc += """

    def by_id(self, event_id: int) -> dict | None:
        cur = self._conn.execute(
            "SELECT id, ts, question, top_sql, safe, cost_ok, preview_rows, ctx, attempts FROM events WHERE id=?",
            (int(event_id),),
        )
        row = cur.fetchone()
        if not row:
            return None
        return {
            "id": int(row[0]),
            "ts": float(row[1]),
            "question": row[2],
            "top_sql": row[3],
            "safe": int(row[4]),
            "cost_ok": int(row[5]),
            "preview_rows": int(row[6]),
        }
    """
ap.write_text(asrc)
print("patched: audit.py")

# --- Fix main.py (remove non-existent explain router if present) ---
mp = Path("backend/app/main.py")
ms = mp.read_text()
if "from backend.app.routers import explain" in ms:
    ms = ms.replace("from backend.app.routers import explain\n", "")
    ms = re.sub(r"\napp\.include_router\(explain\.router.*?\)\n", "\n", ms)
    mp.write_text(ms)
    print("patched: main.py (removed explain router)")
else:
    print("main.py had no explain router (ok)")
PY

# Style & types
ruff check . --fix || true
black . || true
mypy backend || true
