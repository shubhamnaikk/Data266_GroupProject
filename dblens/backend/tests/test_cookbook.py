from backend.app.rag.cookbook import suggest_from_cookbook

CTX = [
    {
        "table": "items",
        "columns": [
            {"column": "id", "type": "int"},
            {"column": "name", "type": "text"},
            {"column": "price", "type": "numeric"},
        ],
    }
]


def test_cookbook_count():
    sql = suggest_from_cookbook("how many rows in items", CTX)
    assert sql and "count" in sql.lower() and "from items" in sql.lower()


def test_cookbook_topn():
    sql = suggest_from_cookbook("show 3 rows", CTX)
    assert sql and "limit 3" in sql.lower()


def test_cookbook_price_under():
    sql = suggest_from_cookbook("items under 2", CTX)
    assert sql and "price <" in sql.lower()
