from fastapi.testclient import TestClient
from backend.app.main import app


def test_ask_persists_event(monkeypatch):
    # simulate guard OFF for tests, or set header if you keep it on
    monkeypatch.delenv("API_KEY", raising=False)
    c = TestClient(app)

    r = c.post("/v1/ask", json={"question": "show 2 rows"})
    assert r.status_code == 200
    j = r.json()
    assert "event_id" in j and isinstance(j["event_id"], int) and j["event_id"] > 0

    r2 = c.get("/v1/history/recent", params={"limit": 3})
    assert r2.status_code == 200
    j2 = r2.json()
    assert j2["ok"] and any("show 2 rows" in it["question"] for it in j2["items"])
