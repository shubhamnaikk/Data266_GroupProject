#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- A) Global JSON error handler in FastAPI ----
python - <<'PY'
from pathlib import Path
p = Path("backend/app/main.py")
s = p.read_text()
added = False
if "from fastapi.responses import JSONResponse" not in s:
    s = s.replace("from fastapi import FastAPI",
                  "from fastapi import FastAPI\nfrom fastapi.responses import JSONResponse\nfrom starlette.requests import Request")
    added = True
if "@app.exception_handler(Exception)" not in s:
    s += """

@app.exception_handler(Exception)
async def _unhandled_error(request: Request, exc: Exception):
    # Ensure we *always* return JSON even on unexpected errors
    from loguru import logger
    logger.exception("unhandled")
    return JSONResponse({"error":"internal_server_error","detail":str(exc)[:200]}, status_code=500)
"""
    added = True
if added:
    p.write_text(s)
    print("patched: backend/app/main.py -> global JSON error handler")
else:
    print("main.py already has JSON error handler")
PY

# ---- B) Retriever fallback when no tokens match ----
python - <<'PY'
from pathlib import Path
p = Path("backend/app/rag/retriever.py")
s = p.read_text()
if "def retrieve_schema_cards(" in s and "if not ranked" not in s:
    s = s.replace(
        "    ranked = sorted(cards, key=score, reverse=True)\n    return ranked[:k]",
        "    ranked = sorted(cards, key=score, reverse=True)\n"
        "    if not ranked:\n"
        "        return []\n"
        "    # if top match has 0 overlap, fall back to first k cards\n"
        "    if score(ranked[0]) == 0:\n"
        "        return cards[:k]\n"
        "    return ranked[:k]"
    )
    p.write_text(s)
    print("patched: backend/app/rag/retriever.py -> fallback when no match")
else:
    print("retriever already patched or unexpected content")
PY

# ---- C) Guard against empty candidate list in pipeline ----
python - <<'PY'
from pathlib import Path
p = Path("backend/app/services/pipeline.py")
s = p.read_text()
if "candidate_sqls = generate_sql_candidates" in s and "if not candidate_sqls" not in s:
    s = s.replace(
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)",
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)\n"
        "    if not candidate_sqls:\n"
        "        candidate_sqls = [\"SELECT 1\"]"
    )
    p.write_text(s)
    print("patched: backend/app/services/pipeline.py -> guard empty candidates")
else:
    print("pipeline empty-candidate guard already present or unexpected content")
PY

echo "✅ Patch applied."
