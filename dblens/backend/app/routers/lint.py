from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import (
    normalize_sql,
    is_safe_select,
    explain_cost_ok,
    summarize_plan,
)

router = APIRouter()
db = DBAgent()


class LintRequest(BaseModel):
    sql: str


@router.post("/lint")
def lint(req: LintRequest):
    sql = normalize_sql(req.sql)
    safe = is_safe_select(sql)
    plan = None
    cost_ok = False
    if safe:
        try:
            plan = db.explain(sql)
            cost_ok = explain_cost_ok(db, sql)
        except Exception as e:
            return {"ok": False, "safe": safe, "cost_ok": False, "error": str(e)[:200]}
    return {
        "ok": True,
        "sql": sql,
        "safe": safe,
        "cost_ok": cost_ok,
        "plan_summary": summarize_plan(plan) if plan else None,
    }
