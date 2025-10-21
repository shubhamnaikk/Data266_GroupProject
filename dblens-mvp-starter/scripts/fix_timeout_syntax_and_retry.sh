#!/usr/bin/env bash
set -euo pipefail

API=${API:-http://localhost:8000}
PG_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}

echo ">> Normalize statement_timeout calls (no params, no extra parens)"
python3 - <<'PY'
import re
from pathlib import Path

roots = [Path("connectors"), Path("services/ingester")]
for root in roots:
    if not root.exists(): continue
    for p in root.rglob("*.py"):
        s0 = s = p.read_text()

        # 1) Drop any parameter tuple on execute("...statement_timeout...", params)
        s = re.sub(
            r'''execute\(\s*          # execute(
                (["\'])               # quote
                \s*SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*[^"']*?\1
                \s*,\s*               # , params
                [^)]+                 # params blob
                \)                    # )
            ''',
            r'execute("SET LOCAL statement_timeout = 5000")',
            s, flags=re.IGNORECASE|re.VERBOSE|re.DOTALL
        )

        # 2) Replace placeholders inside SQL ($1/%s/?) with literal 5000
        s = re.sub(
            r'((?:SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*))(\$[0-9]+|%s|\?)',
            r'\1 5000',
            s, flags=re.IGNORECASE
        )

        # 3) Fix double closing parens after execute("...5000")
        s = re.sub(
            r'execute\(\s*(["\'])SET\s+(?:LOCAL\s+)?statement_timeout\s*(?:=|TO)\s*5000\1\)\)',
            r'execute(\1SET LOCAL statement_timeout = 5000\1)',
            s, flags=re.IGNORECASE
        )

        # 4) Ensure LOCAL is present
        s = re.sub(
            r'execute\(\s*(["\'])SET\s+statement_timeout\s*(?:=|TO)\s*5000\1\)',
            r'execute(\1SET LOCAL statement_timeout = 5000\1)',
            s, flags=re.IGNORECASE
        )

        if s != s0:
            p.write_text(s)
            print(f"patched: {p}")
PY

echo ">> Rebuild API and restart"
docker compose build api >/dev/null
docker compose up -d api >/dev/null

echo ">> Wait for API"
for i in {1..60}; do
  code=$(curl -sS -w '%{http_code}' -o /dev/null "$API/openapi.json" || true)
  [[ "$code" == "200" ]] && { echo "✔ API is up"; break; }
  sleep 0.5
  [[ $i -eq 60 ]] && { echo "✘ API not responding"; docker compose logs --tail 150 api; exit 1; }
done

echo ">> Create/ensure pg-local connection"
resp=$(curl -s -X POST "$API/connections" -H 'Content-Type: application/json' \
  -d "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_DSN\"}")
echo "$resp"
conn_id=$(echo "$resp" | jq -r '.id // empty'); echo "conn_id=$conn_id"
[[ -n "$conn_id" ]]

echo ">> /connections/test"
curl -s "$API/connections/test" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id}" | jq .

echo ">> /schema/cards (first 40 lines)"
curl -s "$API/schema/cards?conn_id=$conn_id" | jq . | head -n 40 || true

echo ">> /preview (select 1)"
curl -s "$API/preview" -H 'Content-Type: application/json' \
  -d "{\"conn_id\":$conn_id,\"sql\":\"select 1\"}" | jq .

echo "✔ Timeout syntax fixed and connector smoke completed"
