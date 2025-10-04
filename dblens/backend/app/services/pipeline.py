from typing import Any, Dict, List, TypedDict, TYPE_CHECKING
from loguru import logger

# Safe/validators & cookbook (keep your existing imports)
from backend.app.validators.safety import (
    is_safe_select,
    explain_cost_ok,
    add_preview_limit,
)
from backend.app.rag.cookbook import suggest_from_cookbook
from backend.app.store.audit import STORE

# Provide a type-only import for static type checkers, and try a runtime import
# with a small stub fallback so tests work without a real DB agent.
if TYPE_CHECKING:
    # for mypy/IDE only - import under a different alias to avoid redefining
    # the runtime name `DBAgent` which we may assign to a stub below.
    pass  # type: ignore

# --- runtime import with clean mypy-friendly fallback ---
try:
    # real implementation (present in normal runs)
    from backend.app.db.agent import DBAgent  # type: ignore[import-not-found]
except Exception:  # pragma: no cover
    # lightweight stub used only if the import is unavailable (e.g. certain tests)
    class _DBAgentStub:
        def list(self) -> list[str]:
            return ["items"]

        def describe(self, table: str) -> dict:
            return {}

        def preview(self, sql: str) -> dict:
            return {"rows": []}

        def explain(self, sql: str) -> dict:
            return {}

    DBAgent = _DBAgentStub  # type: ignore[assignment]


class Candidate(TypedDict, total=False):
    sql: str
    safe: bool
    cost_ok: bool


def ask_plan_approve(question: str) -> dict:
    """
    Plan: pick context tables, propose SQLs (cookbook).
    Approve: safety + cost; add preview limit; pick first passing.
    Return preview for the top passing candidate and persist to history.
    """
    db = DBAgent()

    # --- Build context: discover tables & (optionally) describe them ---
    # Prefer db.list() if available; otherwise fall back to a default.
    tables_func = getattr(db, "list", None)
    tables: List[str] = tables_func() if callable(tables_func) else ["items"]
    if not isinstance(tables, list) or not tables:
        tables = ["items"]

    # Pick context tables by simple heuristic (question mentions table name)
    ql = question.lower()
    ctx_tables = [t for t in tables if t.lower() in ql] or [tables[0]]
    ctx = [{"table": t} for t in ctx_tables]

    # --- Propose candidates (cookbook first), with fallback ---
    candidates_sql: List[str] = []
    try:
        top = suggest_from_cookbook(question, ctx)
        if top:
            candidates_sql.append(top)
    except Exception:
        logger.exception("cookbook suggestion failed")

    if not candidates_sql:
        # Minimal fallback keeps behavior predictable in tests
        candidates_sql.append(f"SELECT * FROM {ctx_tables[0]} LIMIT 5")

    # --- Validate, add preview limits, and choose top passing ---
    resp_candidates: List[Candidate] = []
    top_passing_sql: str | None = None

    for raw_sql in candidates_sql:
        sql_capped = add_preview_limit(raw_sql)
        ok_safe = bool(is_safe_select(sql_capped))
        ok_cost = bool(explain_cost_ok(db, sql_capped)) if ok_safe else False

        resp_candidates.append({"sql": sql_capped, "safe": ok_safe, "cost_ok": ok_cost})

        if ok_safe and ok_cost and top_passing_sql is None:
            top_passing_sql = sql_capped

    # --- Preview only the top passing candidate (if any) ---
    preview: Dict[str, Any] = {"columns": [], "rows": []}
    if top_passing_sql and hasattr(db, "preview"):
        try:
            pv = db.preview(top_passing_sql)
            if isinstance(pv, dict):
                preview = pv
        except Exception:
            logger.exception("preview failed")

    # --- Persist to audit/history (best effort) ---
    try:
        STORE.add_event(
            question=question,
            top_sql=top_passing_sql or resp_candidates[0]["sql"],
            safe=bool(resp_candidates[0]["safe"]),
            cost_ok=bool(resp_candidates[0]["cost_ok"]),
            preview=preview,
            ctx=ctx,
            attempts=[
                {"sql": c["sql"], "safe": c["safe"], "cost_ok": c["cost_ok"]}
                for c in resp_candidates
            ],
        )
    except Exception:
        logger.exception("audit add_event failed")

    return {
        "question": question,
        "context_tables": ctx_tables,
        "candidates": resp_candidates,
        "preview": preview,
    }
