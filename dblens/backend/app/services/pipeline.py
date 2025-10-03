from backend.app.agents.sdk import DBAgent
from backend.app.validators.safety import is_safe_select, explain_cost_ok
from loguru import logger

db = DBAgent()


def ask_plan_approve(question: str):
    # TEMP planner: replace with LLM later
    candidate_sqls = [f"SELECT 1 AS answer /* {question} */"]

    audited = []
    for sql in candidate_sqls:
        safe = is_safe_select(sql)
        cost_ok = explain_cost_ok(db, sql) if safe else False
        audited.append({"sql": sql, "safe": safe, "cost_ok": cost_ok})

    top = next((c for c in audited if c["safe"] and c["cost_ok"]), audited[0])
    preview = (
        db.sample(top["sql"], limit=100) if top["safe"] else {"columns": [], "rows": []}
    )
    logger.bind(event="ask", q=question, audited=audited).info("pipeline")
    return {"question": question, "candidates": audited, "preview": preview}
