import re
from typing import List, Dict
from backend.app.agents.llm import LLMClient

PROMPT_SYS = """You translate questions into safe, efficient PostgreSQL SELECT queries.
Rules:
- SELECT-only (no INSERT/UPDATE/DELETE/DDL).
- Prefer LIMIT 100 for previews.
- Use provided schema only.
Return only SQL, no explanation, no markdown fences.
"""


def _mk_user_prompt(question: str, schema_ctx: List[Dict]) -> str:
    parts = ["Question:", question, "\nSchema:"]
    for c in schema_ctx:
        cols = ", ".join(f"{x['column']}({x['type']})" for x in c["columns"])
        parts.append(f"- {c['table']}: {cols}")
    parts.append("\nExamples:")
    for c in schema_ctx:
        for ex in c["example_queries"][:1]:
            parts.append(f"- {ex}")
    return "\n".join(parts)


def generate_sql_candidates(
    question: str, schema_ctx: List[Dict], n: int = 3
) -> List[str]:
    llm = LLMClient()
    user = _mk_user_prompt(question, schema_ctx)
    outs = llm.chat(
        [{"role": "system", "content": PROMPT_SYS}, {"role": "user", "content": user}],
        n=n,
    )
    cleaned = []
    for o in outs:
        m = re.search(r"```sql(.*?)```", o, flags=re.S | re.I)
        sql = m.group(1).strip() if m else o.strip()
        cleaned.append(sql)
    uniq, seen = [], set()
    for s in cleaned:
        if s not in seen:
            seen.add(s)
            uniq.append(s)
    return uniq
