#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 0) use venv if present
if [ -d ".venv" ]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

# 1) Ensure pipeline actually uses repair_sql; if not, add the self-repair block
python - <<'PY'
from pathlib import Path
p = Path("backend/app/services/pipeline.py")
s = p.read_text()

changed = False

# a) add missing imports if needed
imports = [
    "from backend.app.validators.constrain import constrain_sql",
    "from backend.app.services.self_repair import repair_sql",
]
for imp in imports:
    if imp not in s:
        # insert after the other imports near the top
        lines = s.splitlines()
        idx = 0
        for i, line in enumerate(lines[:80]):
            if line.strip().startswith(("import ", "from ")):
                idx = i + 1
        lines.insert(idx, imp)
        s = "\n".join(lines)
        changed = True

# b) ensure 'allowed' set exists (used by constrain_sql)
if "allowed = {c['table'] for c in ctx}" not in s:
    s = s.replace(
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)",
        "    candidate_sqls = generate_sql_candidates(question, ctx, n=3)\n"
        "    allowed = {c['table'] for c in ctx}"
    )
    changed = True

# c) ensure attempts_log exists
if "attempts_log =" not in s:
    s = s.replace("for sql in candidate_sqls:", "attempts_log = []\n    for sql in candidate_sqls:")
    changed = True

# d) ensure self-repair block exists (look for 'repair_sql(')
if "repair_sql(" not in s:
    # replace the simple preview try with a repairing try
    if 'preview = db.sample(preview_sql, limit=100)' in s:
        s = s.replace(
            '    preview = db.sample(preview_sql, limit=100) if top["safe"] else {"columns": [], "rows": []}',
            '    preview = {"columns": [], "rows": []}\n'
            '    if top["safe"]:\n'
            '        try:\n'
            '            preview = db.sample(preview_sql, limit=100)\n'
            '        except Exception as e:\n'
            '            err = str(e)\n'
            '            for _ in range(2):\n'
            '                fixed = repair_sql(question, ctx, sql_for_preview, err)\n'
            '                ok, reason, fixed = constrain_sql(fixed, allowed)\n'
            '                if not ok or not is_safe_select(fixed) or not explain_cost_ok(db, fixed):\n'
            '                    attempts_log.append({"repair_sql": fixed, "reason": reason})\n'
            '                    continue\n'
            '                try:\n'
            '                    preview_sql = add_preview_limit(fixed, 100)\n'
            '                    preview = db.sample(preview_sql, limit=100)\n'
            '                    audited.insert(0, {"sql": fixed, "safe": True, "cost_ok": True})\n'
            '                    break\n'
            '                except Exception as e2:\n'
            '                    err = str(e2)\n'
            '                    attempts_log.append({"repair_error": err})'
        )
        changed = True

# e) ensure attempts are logged
if 'attempts=attempts_log' not in s and 'logger.bind(' in s:
    s = s.replace(
        'logger.bind(event="ask", q=question, audited=audited, ctx=[c["table"] for c in ctx]).info("pipeline")',
        'logger.bind(event="ask", q=question, audited=audited, attempts=attempts_log, ctx=[c["table"] for c in ctx]).info("pipeline")'
    )
    changed = True

if changed:
    p.write_text(s)
    print("patched: backend/app/services/pipeline.py")
else:
    print("pipeline.py already good")
PY

# 2) Fix E401 in eval/scripts/run_metrics.py (split combined imports)
python - <<'PY'
from pathlib import Path
p = Path("eval/scripts/run_metrics.py")
if p.exists():
    s = p.read_text()
    s_new = s.replace(
        "import csv, time, json, requests, statistics as stats",
        "import csv\nimport time\nimport json\nimport requests\nimport statistics as stats"
    )
    if s_new != s:
        p.write_text(s_new)
        print("patched: eval/scripts/run_metrics.py imports split")
    else:
        print("run_metrics.py imports already split or file changed")
else:
    print("run_metrics.py not found (skipped)")
PY

# 3) Re-run format and lint
ruff check . --fix
black .

echo "✅ Fixes applied. Now stage and commit:"
echo "   git add -A && git commit -m \"Added self-repair loop\""
