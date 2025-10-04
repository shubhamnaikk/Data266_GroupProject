from fastapi.testclient import TestClient
from backend.app.main import app


def test_api_key_guard_blocks(monkeypatch):
    monkeypatch.setenv("API_KEY", "secret")
    c = TestClient(app)
    # missing header should fail
    r = c.post("/v1/lint", json={"sql": "SELECT 1"})
    assert r.status_code == 401
    # with header should pass
    r2 = c.post("/v1/lint", headers={"x-api-key": "secret"}, json={"sql": "SELECT 1"})
    assert r2.status_code == 200
