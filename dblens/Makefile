PY=python
ACT=source .venv/bin/activate
run-api:
	$(ACT); uvicorn backend.app.main:app --reload --port 8000
lint:
	$(ACT); ruff check . && black --check . && mypy backend || true
fmt:
	$(ACT); ruff check --fix .; black .
db-up:
	docker compose -f infra/docker/compose.yml up -d
db-down:
	docker compose -f infra/docker/compose.yml down -v
test:
	$(ACT); PYTHONPATH=. pytest -q
