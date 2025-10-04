#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python - <<'PY'
from pathlib import Path
p = Path("backend/app/services/pipeline.py")
s = p.read_text()
lines = s.splitlines()

imports_to_add = [
    "from backend.app.validators.constrain import constrain_sql",
    "from backend.app.services.self_repair import repair_sql",
]

changed = False
for imp in imports_to_add:
    if imp not in s:
        # find last import near the top (first 80 lines)
        insert_idx = 0
        for i, l in enumerate(lines[:80]):
            ls = l.strip()
            if ls.startswith("from ") or ls.startswith("import "):
                insert_idx = i + 1
        lines.insert(insert_idx, imp)
        changed = True

if changed:
    p.write_text("\n".join(lines))
    print("patched: added missing imports in pipeline.py")
else:
    print("imports already present in pipeline.py")
PY

echo "OK"
