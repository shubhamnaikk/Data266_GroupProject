from backend.app.validators.safety import is_safe_select, add_preview_limit
from backend.app.validators.safety import normalize_sql


def test_blocks_writes():
    assert is_safe_select("INSERT INTO t VALUES (1)") is False
    assert is_safe_select("DROP TABLE x") is False


def test_allows_select():
    assert is_safe_select("SELECT * FROM items") is True


def test_adds_limit():
    s = add_preview_limit("SELECT * FROM items")
    assert "limit" in s.lower()


def test_semicolon_normalization():
    assert normalize_sql("SELECT 1;") == "SELECT 1"
    wrapped = add_preview_limit("SELECT COUNT(*) FROM items;")
    assert "SELECT * FROM (" in wrapped and "LIMIT" in wrapped
