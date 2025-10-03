from typing import Dict, List
from backend.app.agents.sdk import DBAgent


def build_schema_cards() -> List[Dict]:
    db = DBAgent()
    with db._conn.cursor() as cur:  # type: ignore[attr-defined]
        cur.execute(
            """
          select table_name
          from information_schema.tables
          where table_schema='public' and table_type='BASE TABLE'
          order by table_name
        """
        )
        tables = [r[0] for r in cur.fetchall()]
    cards = []
    for t in tables:
        cols = db.describe(t)
        card = {
            "table": t,
            "purpose": f"Table {t} with columns "
            + ", ".join(c["column"] for c in cols),
            "columns": cols,
            "example_queries": [
                f"SELECT * FROM {t} LIMIT 5",
                f"SELECT COUNT(*) FROM {t}",
            ],
        }
        cards.append(card)
    return cards
