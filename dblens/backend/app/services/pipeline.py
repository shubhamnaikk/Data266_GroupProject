from typing import TypedDict, List, cast
from backend.app.agents.sdk import DBAgent
from backend.app.agents.sqlgen import generate_sql_candidates
from backend.app.rag.schema_cards import build_schema_cards
from backend.app.rag.retriever import retrieve_schema_cards
from backend.app.validators.safety import (
    is_safe_select,
    explain_cost_ok,
    add_preview_limit,
    normalize_sql,
)
from loguru import logger


class Candidate(TypedDict):
    sql: str
    safe: bool
    cost_ok: bool


db = DBAgent()
_SCHEMA_CARDS = build_schema_cards()


def ask_plan_approve(question: str):
    ctx = retrieve_schema_cards(question, _SCHEMA_CARDS, k=3)
    candidate_sqls = generate_sql_candidates(question, ctx, n=3)

    audited: List[Candidate] = []
    for sql in candidate_sqls:
        safe = is_safe_select(sql)
        cost_ok = explain_cost_ok(db, sql) if safe else False
        audited.append({"sql": sql, "safe": safe, "cost_ok": cost_ok})

    top = next(
        (c for c in audited if c["safe"] and c["cost_ok"]),
        audited[0] if audited else {"sql": "SELECT 1", "safe": True, "cost_ok": True},
    )
    for sql in candidate_sqls:
        sql = normalize_sql(sql)
        safe = is_safe_select(sql)
        cost_ok = explain_cost_ok(db, sql) if safe else False
        audited.append({"sql": sql, "safe": safe, "cost_ok": cost_ok})

    sql_for_preview = cast(str, top["sql"])
    preview_sql = add_preview_limit(sql_for_preview, 100) if top["safe"] else "SELECT 1"
    preview = (
        db.sample(preview_sql, limit=100)
        if top["safe"]
        else {"columns": [], "rows": []}
    )

    logger.bind(
        event="ask", q=question, audited=audited, ctx=[c["table"] for c in ctx]
    ).info("pipeline")
    return {
        "question": question,
        "context_tables": [c["table"] for c in ctx],
        "candidates": audited,
        "preview": preview,
    }
