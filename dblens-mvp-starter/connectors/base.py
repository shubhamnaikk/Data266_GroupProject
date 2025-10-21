from __future__ import annotations
from urllib.parse import urlparse, parse_qs, unquote
from datetime import date, datetime
from decimal import Decimal

def _json_default(o):
    if isinstance(o, (datetime, date, Decimal)):
        return str(o)
    return o

def _qident(s: str) -> str:
    # naive identifier quoting (double-quote and escape inner quotes)
    s = s.replace('"', '""')
    return f'"{s}"'

class BaseConnector:
    KIND = "base"
    def __init__(self, dsn: str):
        self.dsn = dsn
        self._parsed = urlparse(dsn)

    def test(self) -> dict:
        raise NotImplementedError

    def schema_card(self, max_tables: int = 50, max_samples: int = 5) -> dict:
        raise NotImplementedError
