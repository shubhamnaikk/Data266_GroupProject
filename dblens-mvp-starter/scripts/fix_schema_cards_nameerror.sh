#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Locate FastAPI files that may serve /schema/cards"
CANDIDATES=""
# Prefer root api.py, then anything that mentions the route
[ -f "./api.py" ] && CANDIDATES="./api.py"
FOUND=$(grep -RIl --include='*.py' -E '/schema/cards|def[[:space:]]+schema_cards' . 2>/dev/null || true)
if [ -n "${FOUND:-}" ]; then
  for f in $FOUND; do
    case " $CANDIDATES " in
      *" $f "*) : ;; # dedupe
      *) CANDIDATES="$CANDIDATES $f" ;;
    esac
  done
fi

if [ -z "${CANDIDATES// /}" ]; then
  echo "✘ Could not find any API file defining /schema/cards"; exit 1
fi
echo "$CANDIDATES" | tr ' ' '\n' | sed '/^$/d' | sed 's/^/   found: /'

python3 - <<'PY'
import re, sys, os
from pathlib import Path

# stdin unused; we just iterate over candidates passed via env var
cands = os.environ.get("PATCH_CANDS","").split()
if not cands:
    print("✘ No PATCH_CANDS provided"); sys.exit(1)

def patch_file(path: Path):
    s = path.read_text()
    orig = s

    # Ensure json is imported (simple, duplicate-safe)
    if "import json" not in s:
        s = "import json\n" + s

    # Inject _jd helper if missing
    if "def _jd(" not in s:
        helper = """
# --- JSON default encoder for datetimes/decimals/others ---
def _jd(obj):
    try:
        import datetime, decimal
        if isinstance(obj, (datetime.datetime, datetime.date)):
            return obj.isoformat()
        if isinstance(obj, decimal.Decimal):
            return float(obj)
    except Exception:
        pass
    return str(obj)
# ----------------------------------------------------------
"""
        # Put helper right after first import json occurrence
        s = s.replace("import json", "import json\n"+helper, 1)

    # Remove illegal dict.get(..., default=_jd)
    s = re.sub(r't\.get\(\s*([\'"])columns\1\s*,\s*\[\]\s*,\s*default\s*=\s*_jd\s*\)',
               r't.get(\1columns\1, [])', s)
    s = re.sub(r't\.get\(\s*([\'"])samples\1\s*,\s*\{\}\s*,\s*default\s*=\s*_jd\s*\)',
               r't.get(\1samples\1, {})', s)

    # Ensure json.dumps(... default=_jd) for columns and samples
    def ensure_default(m):
        g = m.group(0)
        return g if 'default=_jd' in g else g[:-1] + ', default=_jd)'

    s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\'"])columns\1\s*,\s*\[\]\s*\)\s*\)',
               ensure_default, s)
    s = re.sub(r'json\.dumps\(\s*t\.get\(\s*([\'"])samples\1\s*,\s*\{\}\s*\)\s*\)',
               ensure_default, s)
    # Also catch any other dumps mentioning columns/samples
    s = re.sub(r'json\.dumps\([^)]*columns[^)]*\)', ensure_default, s)
    s = re.sub(r'json\.dumps\([^)]*samples[^)]*\)', ensure_default, s)

    if s != orig:
        path.write_text(s)
        print(f"patched: {path}")
    else:
        print(f"no changes: {path}")

# Drive
for p in cands:
    pth = Path(p)
    if pth.exists():
        # backup once
        try:
            backup = pth.with_suffix(pth.suffix + ".bak")
            if not backup.exists():
                backup.write_text(pth.read_text())
        except Exception:
            pass
        patch_file(pth)
    else:
        print(f"skip, missing: {pth}")
PY
# Export candidates to the Python patcher
PATCH_CANDS="$(echo $CANDIDATES)"
export PATCH_CANDS

echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API"
for i in $(seq 1 60); do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [ "$code" = "200" ] && { echo "✔ API reachable"; break; }
  sleep 0.5
  [ $i -eq 60 ] && { echo "✘ API not responding"; docker compose logs --tail 200 api; exit 1; }
done

echo ">> Ensure pg-local connection"
resp="$(curl -sS -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")"
echo "$resp"
conn_id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
[ -n "${conn_id:-}" ] || { echo "✘ could not parse conn_id from /connections"; exit 1; }
echo "conn_id=$conn_id"

echo ">> GET /schema/cards"
hdr=$(mktemp); body=$(mktemp)
code=$(curl -sS -D "$hdr" -o "$body" -w '%{http_code}' "$API/schema/cards?conn_id=$conn_id" || echo "000")
ctype=$(grep -i '^content-type:' "$hdr" | tr -d '\r' | awk '{print tolower($0)}' || true)
echo "HTTP $code | $ctype"
head -n 80 "$body" || true

if [ "$code" != "200" ] || [[ "$ctype" != *"application/json"* ]]; then
  echo "!! /schema/cards still failing. API log tail:"
  docker compose logs --tail 200 api
  exit 1
fi

echo ">> Sanity: /preview select 1"
curl -sS "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | sed -n '1,80p'

echo "✔ Fixed _jd and JSON serialization in /schema/cards."
