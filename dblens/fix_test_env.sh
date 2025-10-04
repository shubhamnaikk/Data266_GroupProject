#!/usr/bin/env bash
set -euo pipefail

# --- sanity: run from repo root ---
if [ ! -f "backend/app/main.py" ]; then
  echo "❌ Run this from the dblens repo root (where backend/app/main.py exists)."
  exit 1
fi

# --- ensure venv exists & active ---
PY_CMD="${PY_CMD:-python3.11}"
command -v "$PY_CMD" >/dev/null 2>&1 || PY_CMD="python3"

if [ ! -d ".venv" ]; then
  echo "==> Creating .venv"
  "$PY_CMD" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

# --- make sure required packages are in THIS venv ---
echo "==> Installing/refreshing core deps (in .venv)"
python -m pip install -U pip >/dev/null
python -m pip install -U sqlglot pytest requests >/dev/null

# optional (keeps your lint hooks happy if missing):
python -m pip install -U ruff black mypy pydantic-settings types-requests >/dev/null || true

# --- ensure pytest can import 'backend' without manual PYTHONPATH ---
if [ ! -f "conftest.py" ]; then
  cat > conftest.py <<'PY'
import sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
PY
  echo "==> Wrote conftest.py to add repo root to sys.path"
fi

# --- ensure Makefile has a 'test' target using PYTHONPATH=. ---
if [ -f Makefile ] && ! grep -q "^test:" Makefile; then
  cat >> Makefile <<'MAKE'

test:
	$(ACT); PYTHONPATH=. pytest -q
MAKE
  echo "==> Added 'make test' target"
else
  # patch existing test target to include PYTHONPATH=.
  perl -0777 -pe 's/test:\n\t\$(ACT);[^\n]*/test:\n\t$(ACT); PYTHONPATH=. pytest -q/' -i Makefile 2>/dev/null || true
fi

# --- add a handy wrapper so tests always run with the venv ---
mkdir -p scripts
cat > scripts/pt <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
# run tests using the project's venv and correct PYTHONPATH
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
# shellcheck disable=SC1091
source .venv/bin/activate
PYTHONPATH=. pytest -q "$@"
BASH
chmod +x scripts/pt
echo "==> Added ./scripts/pt (project test runner)"

echo
echo "✅ Test environment patched."
echo "Try one of these:"
echo "  1) ./scripts/pt"
echo "  2) make test"
echo "  3) PYTHONPATH=. pytest -q"
