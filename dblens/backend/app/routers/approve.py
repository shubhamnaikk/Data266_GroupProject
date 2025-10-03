from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import is_safe_select
from backend.app.validators.safety import normalize_sql

router = APIRouter()
db = DBAgent()


class ApproveRequest(BaseModel):
    sql: str


@router.post("/approve")
def approve(req: ApproveRequest):
    sql = normalize_sql(req.sql)
    if not is_safe_select(sql):
        return {"ok": False, "error": "Unsafe SQL blocked"}
    res = db.execute_readonly(sql)
    return {"ok": True, "result": res}
