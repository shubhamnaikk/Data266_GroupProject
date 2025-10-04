from fastapi import APIRouter
from pydantic import BaseModel
from loguru import logger
from backend.app.services.pipeline import ask_plan_approve
from backend.app.store.audit import STORE

router = APIRouter()


class AskRequest(BaseModel):
    question: str


@router.post("/ask")
def ask(req: AskRequest):
    resp = ask_plan_approve(req.question)
    # Persist audit (robust defaults)
    try:
        top = (resp.get("candidates") or [{}])[0]
        ctx_tables = resp.get("context_tables") or []
        preview = resp.get("preview") or {}
        attempts = resp.get("attempts", [])  # ok if not present
        event_id = STORE.add_event(
            req.question,
            top.get("sql", ""),
            bool(top.get("safe")),
            bool(top.get("cost_ok")),
            preview,
            ctx_tables,
            attempts,
        )
    except Exception as e:
        logger.error(f"audit_store_failed (router): {e}")
        event_id = -1
    resp["event_id"] = event_id
    return resp
