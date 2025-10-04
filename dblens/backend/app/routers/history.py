from fastapi import APIRouter
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
    rec = STORE.by_id(event_id)
    if not rec:
        return {"ok": False, "error": "not_found"}
    return {"ok": True, "item": rec}
