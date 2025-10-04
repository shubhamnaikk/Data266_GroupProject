import re
from typing import List, Dict, Optional
import yaml  # type: ignore[import-untyped]


def _pick_primary_table(ctx: List[Dict]) -> Optional[str]:
    return ctx[0]["table"] if ctx else None


def _find_n(q: str) -> Optional[int]:
    m = re.search(r"\b(\d+)\b", q)
    return int(m.group(1)) if m else None


def _extract_threshold(q: str) -> float:
    m = re.search(r"(\d+(\.\d+)?)", q)
    return float(m.group(1)) if m else 1.0


def suggest_from_cookbook(question: str, ctx: List[Dict]) -> Optional[str]:
    try:
        spec = yaml.safe_load(open("backend/app/rag/cookbook.yaml"))
    except Exception:
        return None

    table = _pick_primary_table(ctx)
    if not table:
        return None

    q = question.lower()
    for p in spec.get("patterns", []):
        keywords = p.get("when_any") or []
        if any(kw in q for kw in keywords):
            sql_tmpl = p["sql"]

            if "{n}" in sql_tmpl:
                n = _find_n(q)
                if n is None:
                    n = int(p.get("default_n", 5))
                return sql_tmpl.format(table=table, n=n)

            if "{threshold}" in sql_tmpl:
                # prefer value from the question; if none, use default_threshold
                val = _extract_threshold(q)
                if re.search(r"(\d+(\.\d+)?)", q) is None:
                    val = float(p.get("default_threshold", 1))
                return sql_tmpl.format(table=table, threshold=val)

            return sql_tmpl.format(table=table)

    return None
