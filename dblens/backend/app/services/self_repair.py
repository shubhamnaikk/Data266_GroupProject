import re
from typing import Dict, List
from backend.app.agents.llm import LLMClient

_SYS = """You are a SQL fixer. Repair the provided PostgreSQL SELECT query to satisfy:
- Use only the provided schema tables/columns.
- Keep it SELECT-only.
- If a column is wrong, replace it with the closest valid one.
- Return ONLY the SQL (no commentary, no markdown)."""


def _schema_block(schema_ctx: List[Dict]) -> str:
    parts = []
    for c in schema_ctx:
        cols = ", ".join(f"{x['column']}({x['type']})" for x in c["columns"])
        parts.append(f"- {c['table']}: {cols}")
    return "\n".join(parts)


def repair_sql(
    question: str, schema_ctx: List[Dict], bad_sql: str, db_error: str
) -> str:
    llm = LLMClient()
    user = (
        f"Question:\n{question}\n\n"
        f"Schema:\n{_schema_block(schema_ctx)}\n\n"
        f"Previous SQL:\n{bad_sql}\n\n"
        f"Database error:\n{db_error}\n\n"
        "Return a corrected SQL."
    )
    out = llm.chat(
        [{"role": "system", "content": _SYS}, {"role": "user", "content": user}], n=1
    )[0]
    m = re.search(r"```sql(.*?)```", out, flags=re.S | re.I)
    return (m.group(1) if m else out).strip()
