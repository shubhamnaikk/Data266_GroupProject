from fastapi import APIRouter
from pydantic import BaseModel
from backend.app.services.pipeline import ask_plan_approve

router = APIRouter()


class AskRequest(BaseModel):
    question: str


@router.post("/ask")
def ask(req: AskRequest):
    return ask_plan_approve(req.question)
