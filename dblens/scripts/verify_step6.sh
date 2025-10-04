#!/usr/bin/env bash
set -euo pipefail

HDR=()
grep -q '^API_KEY=' .env && HDR=(-H "x-api-key: $(grep '^API_KEY=' .env|cut -d= -f2)")

echo "1) routes present?"
curl -s http://localhost:8000/openapi.json \
| python -c 'import sys,json; p=json.load(sys.stdin)["paths"].keys(); print("OK" if "/v1/history/recent" in p else "MISSING")'

echo "2) ask (create event)"
E=$(curl -s "${HDR[@]}" -H "Content-Type: application/json" -d '{"question":"Show 5 rows from items"}' http://localhost:8000/v1/ask \
 | python -c 'import sys,json;print(json.load(sys.stdin).get("event_id",-1))')
echo "event_id=$E"

echo "3) recent:"
curl -s "${HDR[@]}" 'http://localhost:8000/v1/history/recent?limit=3' | python -m json.tool | sed -n '1,40p'

echo "4) by id:"
curl -s "${HDR[@]}" "http://localhost:8000/v1/history/$E" | python -m json.tool | sed -n '1,60p'

echo "5) guard negative (skip if no API_KEY):"
if [ ${#HDR[@]} -eq 0 ]; then
  echo "guard disabled (no API_KEY in .env)"
else
  curl -i -s -X POST http://localhost:8000/v1/lint -H "Content-Type: application/json" -d '{"sql":"SELECT 1"}' | sed -n '1,8p' || true
fi

echo "DONE"
