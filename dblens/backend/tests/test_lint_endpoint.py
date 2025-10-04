from fastapi.testclient import TestClient
from backend.app.main import app

client = TestClient(app)


def test_lint_ok():
    r = client.post("/v1/lint", json={"sql": "SELECT 1"})
    j = r.json()
    assert j["ok"] is True
    assert j["safe"] is True
