#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# --- 1) Canonicalize backend/app/main.py (imports on top, single api_key_guard) ---
python - <<'PY'
from pathlib import Path
p = Path("backend/app/main.py")
src = p.read_text()

canonical = '''from fastapi import FastAPI, Header, HTTPException, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger
import os

from backend.app.routers import ask, approve, lint, explain, history

app = FastAPI(title="DBLens", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

def api_key_guard(x_api_key: str | None = Header(default=None)):
    need = os.getenv("API_KEY")
    if need and x_api_key != need:
        raise HTTPException(status_code=401, detail="invalid api key")

app.include_router(ask.router,     prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(approve.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(lint.router,    prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(explain.router, prefix="/v1", dependencies=[Depends(api_key_guard)])
app.include_router(history.router, prefix="/v1", dependencies=[Depends(api_key_guard)])

@app.exception_handler(Exception)
async def _unhandled_error(request: Request, exc: Exception):
    # Let FastAPI render the default error after logging
    logger.error("unhandled", exception=exc)
    raise exc
'''
# only overwrite if routers import exists in project; otherwise fall back to minimal set
if "backend/app/routers/explain.py" not in [str(x) for x in Path("backend/app/routers").glob("*.py")]:
    canonical = canonical.replace("from backend.app.routers import ask, approve, lint, explain, history",
                                  "from backend.app.routers import ask, approve, lint, history").replace(
                                  "app.include_router(explain.router, prefix=\"/v1\", dependencies=[Depends(api_key_guard)])\n","")

p.write_text(canonical)
print("patched main.py")
PY

# --- 2) Clean pipeline: remove unused STORE import and dead ctx_tables assignment ---
python - <<'PY'
from pathlib import Path, re
p = Path("backend/app/services/pipeline.py")
s = p.read_text()

# remove unused STORE import
s = s.replace("from backend.app.store.audit import STORE\n", "")

# drop one-off dead assignment if still present
s = s.replace('ctx_tables = [c["table"] for c in ctx]\n', "")

# keep logger.bind(ctx=[...]) as-is; do not inject event persistence here (router does it)
p.write_text(s)
print("patched pipeline.py (removed unused import/assignment)")
PY

# --- 3) Fix mypy in audit: avoid int(None)/int(list); compute preview_rows safely ---
python - <<'PY'
from pathlib import Path, re
p = Path("backend/app/store/audit.py")
s = p.read_text()

# Replace any explicit int(...) preview_rows assignment with a safe length computation
s2 = re.sub(
    r'preview_rows\s*=\s*int\([^)]*\)',
    'preview_rows = (len(preview.get("rows")) if isinstance(preview, dict) and isinstance(preview.get("rows"), list) else 0)',
    s
)

# If there is no assignment at all, inject one just before INSERT execution.
if "preview_rows =" not in s2 and "INSERT INTO events" in s2:
    s2 = s2.replace(
        "INSERT INTO events",
        'preview_rows = (len(preview.get("rows")) if isinstance(preview, dict) and isinstance(preview.get("rows"), list) else 0)\n        INSERT INTO events'
    )

Path("backend/app/store/audit.py").write_text(s2)
print("patched audit.py (safe preview_rows)")
PY

# --- Style & types ---
ruff check . --fix || true
black . || true
mypy backend || true

echo "✅ Fixes applied. Try committing again."
