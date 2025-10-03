#!/usr/bin/env bash
set -euo pipefail

# E401 in backend/app/agents/sdk.py (split imports)
python - <<'PY'
import pathlib, re
p=pathlib.Path("backend/app/agents/sdk.py")
s=p.read_text()
s=re.sub(r'^(import psycopg),\s*os\s*$', r'\1\nimport os', s, flags=re.M)
p.write_text(s)
print("fixed: sdk.py imports")
PY

# E702 in backend/app/agents/sqlgen.py (no semicolon one-liner)
python - <<'PY'
from pathlib import Path
p=Path("backend/app/agents/sqlgen.py")
s=p.read_text()
s=s.replace("seen.add(s); uniq.append(s)", "seen.add(s)\n            uniq.append(s)")
p.write_text(s)
print("fixed: sqlgen.py one-liner")
PY

# F811 in backend/app/services/pipeline.py (duplicate imports; keep the line with normalize_sql)
python - <<'PY'
from pathlib import Path
p=Path("backend/app/services/pipeline.py")
lines=p.read_text().splitlines()
out=[]; kept=False
for line in lines:
    if line.strip().startswith("from backend.app.validators.safety import is_safe_select"):
        if not kept and "normalize_sql" in line:
            kept=True; out.append(line)
        elif not kept and "normalize_sql" not in line:
            # skip this earlier duplicate; keep the later one
            continue
        else:
            # any further duplicates -> skip
            continue
    else:
        out.append(line)
p.write_text("\n".join(out))
print("fixed: pipeline.py duplicate imports")
PY

# E702 in eval/scripts/run_eval_toy.py (split one-liner)
python - <<'PY'
from pathlib import Path
p=Path("eval/scripts/run_eval_toy.py")
s=p.read_text()
s=s.replace("latencies.append(dt); oks += int(ok)", "latencies.append(dt)\noks += int(ok)")
p.write_text(s)
print("fixed: run_eval_toy.py one-liner")
PY

# E401 in eval/scripts/run_smoke.py (split imports)
python - <<'PY'
from pathlib import Path
p=Path("eval/scripts/run_smoke.py")
s=p.read_text()
s=s.replace("import time, json, requests", "import time\nimport json\nimport requests")
p.write_text(s)
print("fixed: run_smoke.py imports")
PY

echo "✅ Applied lint fixes."
