from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from typing import Any, Dict, List, Optional

_DB_PATH = os.getenv("DBLENS_AUDIT_DB", "logs/audit.db")


class AuditStore:
    def __init__(self, path: str = _DB_PATH) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL,
              question TEXT,
              top_sql TEXT,
              safe INTEGER,
              cost_ok INTEGER,
              preview_rows INTEGER,
              ctx TEXT,
              attempts TEXT
            );
            """
        )
        self._lock = threading.Lock()

    def add_event(
        self, question, top_sql, safe, cost_ok, preview, ctx, attempts
    ) -> int:
        rows = preview.get("rows") if isinstance(preview, dict) else None
        rows_list = rows if isinstance(rows, list) else []
        preview_rows = len(rows_list)

        ctx_json = json.dumps(ctx)
        attempts_json = json.dumps(attempts)

        cur = self._conn.execute(
            "INSERT INTO events(ts, question, top_sql, safe, cost_ok, preview_rows, ctx, attempts) "
            "VALUES(?,?,?,?,?,?,?,?)",
            (
                time.time(),
                question,
                top_sql,
                int(bool(safe)),
                int(bool(cost_ok)),
                preview_rows,
                ctx_json,
                attempts_json,
            ),
        )
        lid = cur.lastrowid
        return int(lid) if lid is not None else 0

    def recent(self, limit: int = 10) -> List[Dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT id, ts, question, top_sql, safe, cost_ok, preview_rows "
            "FROM events ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [
            {
                "id": r[0],
                "ts": r[1],
                "question": r[2],
                "top_sql": r[3],
                "safe": r[4],
                "cost_ok": r[5],
                "preview_rows": r[6],
            }
            for r in rows
        ]

    def by_id(self, event_id: int) -> Optional[Dict[str, Any]]:
        row = self._conn.execute(
            "SELECT id, ts, question, top_sql, safe, cost_ok, preview_rows, ctx, attempts "
            "FROM events WHERE id = ?",
            (event_id,),
        ).fetchone()
        if not row:
            return None
        return {
            "id": row[0],
            "ts": row[1],
            "question": row[2],
            "top_sql": row[3],
            "safe": row[4],
            "cost_ok": row[5],
            "preview_rows": row[6],
            "ctx": json.loads(row[7] or "[]"),
            "attempts": json.loads(row[8] or "[]"),
        }


STORE = AuditStore()
