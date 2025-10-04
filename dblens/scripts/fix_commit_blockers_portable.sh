#!/usr/bin/env bash
set -euo pipefail

BASE="."
if [ ! -f "backend/app/services/pipeline.py" ]; then
  if [ -f "dblens/backend/app/services/pipeline.py" ]; then
    BASE="dblens"
  else
    echo "❌ Could not find backend/app/services/pipeline.py in . or ./dblens"
    exit 1
  fi
fi

PIPE="$BASE/backend/app/services/pipeline.py"
METR="$BASE/eval/scripts/run_metrics.py"

python - <<PY
from pathlib import Path
pipe = Path("$PIPE")
s = pipe.read_text()
changed = False

# ensure constrain_sql import
if "from backend.app.validators.constrain import constrain_sql" not in s:
    lines = s.splitlines()
    idx = 0
    for i,l in enumerate(lines[:80]):
        if l.startswith("from backend.app.validators.safety"):
            idx = i+1
    lines.insert(idx, "from backend.app.validators.constrain import constrain_sql")
    s = "\n".join(lines)
    changed = True

uses_repair = "repair_sql(" in s
has_import = "from backend.app.services.self_repair import repair_sql" in s

if uses_repair and not has_import:
    lines = s.splitlines()
    idx = 0
    for i,l in enumerate(lines[:80]):
        if l.startswith("from backend.app.validators.constrain"):
            idx = i+1
    lines.insert(idx, "from backend.app.services.self_repair import repair_sql")
    s = "\n".join(lines)
    changed = True
elif not uses_repair and has_import:
    s = s.replace("from backend.app.services.self_repair import repair_sql\n","")
    changed = True

if changed:
    pipe.write_text(s)
    print("patched", pipe)
else:
    print("no changes needed for", pipe)
PY

if [ -f "$METR" ]; then
  python - <<PY
from pathlib import Path
p = Path("$METR")
s = p.read_text()
ns = s.replace("import csv, time, json, requests, statistics as stats",
               "import csv\nimport time\nimport json\nimport requests\nimport statistics as stats")
if ns != s:
    p.write_text(ns)
    print("patched", p)
else:
    print("no changes needed for", p)
PY
fi

ruff check "$BASE" --fix || true
black "$BASE" || true
echo "DONE"
