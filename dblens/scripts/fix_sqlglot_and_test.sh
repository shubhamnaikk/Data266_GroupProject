#!/usr/bin/env bash
set -euo pipefail

# move to repo root if running from subdir
cd "$(dirname "$0")/.."

# 1) ensure venv
PY_CMD="${PY_CMD:-python3.11}"
command -v "$PY_CMD" >/dev/null 2>&1 || PY_CMD="python3"
if [ ! -d ".venv" ]; then
  echo "==> creating .venv with $PY_CMD"
  "$PY_CMD" -m venv .venv
fi

# 2) install deps INTO THE VENV
echo "==> installing sqlglot + test deps into .venv"
./.venv/bin/python -m pip install -U pip >/dev/null
./.venv/bin/python -m pip install -U sqlglot pytest requests >/dev/null

# 3) verify interpreter & sqlglot
echo "==> verifying environment"
./.venv/bin/python - <<'PY'
import sys
import sqlglot
print("python:", sys.executable)
print("sqlglot:", sqlglot.__version__)
PY

# 4) run tests with venv python and proper PYTHONPATH
echo "==> running tests"
PYTHONPATH=. ./.venv/bin/python -m pytest -q
