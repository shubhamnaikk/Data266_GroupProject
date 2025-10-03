import re
import sqlglot

FORBIDDEN = r"\\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE)\\b"


def is_safe_select(sql: str) -> bool:
    if re.search(FORBIDDEN, sql, re.IGNORECASE):
        return False
    try:
        parsed = sqlglot.parse_one(sql)
        return bool(parsed) and parsed.key.upper() == "SELECT"
    except Exception:
        return False


def explain_cost_ok(db, sql: str, max_rows: int = 1_000_000) -> bool:
    try:
        plan = db.explain(sql)
        est = plan.get("Plan", {}).get("Plan Rows")
        if est is None:
            # fallback: ok if we can't read the estimate
            return True
        return int(est) <= max_rows
    except Exception:
        return False
