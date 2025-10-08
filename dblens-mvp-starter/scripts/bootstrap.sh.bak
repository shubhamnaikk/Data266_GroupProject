#!/usr/bin/env bash
set -euo pipefail
file="scripts/bootstrap.sh"
cp -n "$file" "${file}.bak" || true

python3 - <<'PY'
from pathlib import Path
p = Path("scripts/bootstrap.sh")
s = p.read_text()

s = s.replace(
    "ALTER SYSTEM SET statement_timeout = '15s';",
    "\n-- Role-scoped timeouts (safer than ALTER SYSTEM)\n"
    "ALTER ROLE app_ro    SET statement_timeout = '15s';\n"
    "ALTER ROLE loader_rw SET statement_timeout = '30s';"
)

Path("scripts/bootstrap.sh").write_text(s)
print("Patched scripts/bootstrap.sh (removed ALTER SYSTEM; added ALTER ROLE timeouts).")
PY

echo "Now re-run: bash scripts/bootstrap.sh"
