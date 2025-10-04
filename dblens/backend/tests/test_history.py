from fastapi.testclient import TestClient
from backend.app.main import app


def test_history_recent_populates():
    c = TestClient(app)
    # trigger an event
    r = c.post("/v1/ask", json={"question": "Show 5 rows from items"})
    assert r.status_code == 200
    # fetch history
    r2 = c.get("/v1/history/recent?limit=5")
    j = r2.json()
    assert j["ok"] is True
    assert isinstance(j["items"], list)
    assert any("Show 5 rows" in (it.get("question") or "") for it in j["items"])


def test_history_by_id_roundtrip():
    c = TestClient(app)
    r = c.post("/v1/ask", json={"question": "How many rows are in items?"})
    eid = r.json().get("event_id")
    r2 = c.get(f"/v1/history/{eid}")
    assert r2.status_code == 200
    assert r2.json()["ok"] is True
