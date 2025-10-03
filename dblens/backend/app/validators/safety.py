import re
import sqlglot

FORBIDDEN = r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE)\b"


def normalize_sql(sql: str) -> str:
    # strip trailing semicolons / whitespace
    return sql.rstrip().rstrip(";").rstrip()


def is_safe_select(sql: str) -> bool:
    sql = normalize_sql(sql)
    if re.search(FORBIDDEN, sql, re.IGNORECASE):
        return False
    try:
        parsed = sqlglot.parse_one(sql)
        return bool(parsed) and parsed.key.upper() == "SELECT"
    except Exception:
        return False


def explain_cost_ok(db, sql: str, max_rows: int = 1_000_000) -> bool:
    sql = normalize_sql(sql)
    try:
        plan = db.explain(sql)
        est = plan.get("Plan", {}).get("Plan Rows")
        return True if est is None else int(est) <= max_rows
    except Exception:
        return False


def add_preview_limit(sql: str, default_limit: int = 100) -> str:
    sql = normalize_sql(sql)
    low = sql.lower()
    if " limit " in low:
        return sql
    return f"SELECT * FROM ({sql}) t LIMIT {default_limit}"
