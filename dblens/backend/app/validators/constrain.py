from typing import Tuple, Set
import sqlglot
from sqlglot import exp
from backend.app.validators.safety import normalize_sql, is_safe_select

BLOCKED_SCHEMAS = {"pg_catalog", "information_schema"}


def _refs(parsed: exp.Expression) -> Set[str]:
    names: Set[str] = set()
    for t in parsed.find_all(exp.Table):
        # table name without schema
        tbl = (t.this.name if hasattr(t.this, "name") else str(t.this)).lower()
        names.add(tbl)
    return names


def constrain_sql(sql: str, allowed_tables: Set[str]) -> Tuple[bool, str, str]:
    """
    Enforce: SELECT-only, no system schemas, tables must be from allowed_tables.
    Returns (ok, reason, fixed_sql).
    """
    fixed = normalize_sql(sql)
    if not is_safe_select(fixed):
        return False, "not_select_or_forbidden", fixed
    try:
        parsed = sqlglot.parse_one(fixed, read="postgres")
    except Exception as e:
        return False, f"parse_error:{type(e).__name__}", fixed

    # block system schemas
    for t in parsed.find_all(exp.Table):
        sch = (str(t.db) if t.db is not None else "").lower()
        if sch in BLOCKED_SCHEMAS:
            return False, "blocked_schema", fixed

    # whitelist tables from context
    refs = _refs(parsed)
    if allowed_tables:
        allowed = {a.lower() for a in allowed_tables}
        for r in refs:
            if r not in allowed:
                return False, f"unknown_table:{r}", fixed

    return True, "ok", fixed
