from backend.app.validators.constrain import constrain_sql


def test_blocks_system_schema():
    ok, reason, _ = constrain_sql("SELECT * FROM pg_catalog.pg_class", {"items"})
    assert not ok and reason == "blocked_schema"


def test_blocks_unknown_table():
    ok, reason, _ = constrain_sql("SELECT * FROM nope", {"items"})
    assert not ok and reason.startswith("unknown_table")


def test_allows_known_table_and_select():
    ok, reason, fixed = constrain_sql("SELECT * FROM items LIMIT 2;", {"items"})
    assert ok and reason == "ok"
    assert fixed.endswith("LIMIT 2")
