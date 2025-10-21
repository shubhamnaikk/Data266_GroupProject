#!/usr/bin/env bash
# scripts/test_connectors_smoke.sh
set -euo pipefail

API=${API:-http://localhost:8000}
PG_TEST_DSN=${PG_TEST_DSN:-"postgresql://app_ro:app_ro_pass@postgres:5432/dblens"}
MYSQL_PORT=${MYSQL_PORT:-3307}
MYSQL_CONTAINER=${MYSQL_CONTAINER:-dblens-mysql-test}
MYSQL_TEST_DSN=${MYSQL_TEST_DSN:-"mysql+pymysql://ro:ro@host.docker.internal:${MYSQL_PORT}/sample"}
SNOWFLAKE_DSN=${SNOWFLAKE_DSN:-}   # e.g. snowflake://USER:PASS@ACCOUNT/DB/SCHEMA?role=READONLY&warehouse=XS_WH

RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); YLW=$(printf '\033[33m'); NC=$(printf '\033[0m')
pass(){ echo "${GRN}✔ $*${NC}"; }
warn(){ echo "${YLW}△ $*${NC}"; }
fail(){ echo "${RED}✘ $*${NC}"; exit 1; }

need() { command -v "$1" >/dev/null || fail "Missing required command: $1"; }
need docker; need curl; need python3

curl_json () {
  local method="$1" path="$2" data="${3:-}"
  local tmp="$(mktemp)" code
  if [[ -n "$data" ]]; then
    code=$(curl -sS -X "$method" -H 'Content-Type: application/json' -d "$data" -w '%{http_code}' -o "$tmp" "$API$path" || true)
  else
    code=$(curl -sS -X "$method" -w '%{http_code}' -o "$tmp" "$API$path" || true)
  fi
  echo "$code" "$tmp"
}

json_field () {
  # usage: json_field <file> <python-expr using j> ; prints value or empty
  python3 - "$1" "$2" <<'PY'
import sys, json
fp, expr = sys.argv[1], sys.argv[2]
try:
  with open(fp,'rb') as f: j=json.load(f)
  v=eval(expr, {"__builtins__":{}}, {"j":j})
  print(v if v is not None else "")
except Exception: print("")
PY
}

echo "== Sanity: API up =="
read code tmp < <(curl_json GET /openapi.json)
[[ "$code" == "200" ]] && pass "OpenAPI reachable" || { echo "HTTP $code"; cat "$tmp"; fail "API not responding"; }
rm -f "$tmp"

############################################
# 1) Postgres external (local control-plane as smoke)
############################################
echo "== Postgres connector smoke (using local app_ro DSN) =="

read code tmp < <(curl_json POST /connections "{\"name\":\"pg-local\",\"driver\":\"postgres\",\"dsn\":\"$PG_TEST_DSN\"}")
[[ "$code" == "200" ]] || { echo "HTTP $code"; cat "$tmp"; fail "POST /connections failed"; }
PG_CONN_ID=$(json_field "$tmp" 'j.get("id")'); rm -f "$tmp"
[[ -n "$PG_CONN_ID" && "$PG_CONN_ID" != "None" ]] || fail "Could not parse pg connection id"

read code tmp < <(curl_json POST /connections/test "{\"conn_id\":$PG_CONN_ID}")
[[ "$code" == "200" ]] || { echo "HTTP $code"; cat "$tmp"; fail "connections/test (pg) failed"; }
RO=$(json_field "$tmp" 'j.get("read_only_verified")'); rm -f "$tmp"
[[ "$RO" == "True" ]] && pass "pg read-only verified" || warn "pg read-only not verified (may still be enforced by validator)"

read code tmp < <(curl_json GET "/schema/cards?conn_id=$PG_CONN_ID")
[[ "$code" == "200" ]] || { echo "HTTP $code"; cat "$tmp"; fail "schema/cards (pg) failed"; }
grep -q '"airtravel"' "$tmp" && pass "pg schema includes airtravel (expected from earlier ingest)" || warn "pg schema visible (airtravel not found — ok if not ingested)"
rm -f "$tmp"

read code tmp < <(curl_json POST /preview "{\"conn_id\":$PG_CONN_ID,\"sql\":\"select 1\"}")
[[ "$code" == "200" ]] && pass "pg preview ok" || { echo "HTTP $code"; cat "$tmp"; fail "pg preview failed"; }
rm -f "$tmp"

read code tmp < <(curl_json POST /validate "{\"conn_id\":$PG_CONN_ID,\"sql\":\"select * from airtravel limit 3\"}")
[[ "$code" == "200" ]] && pass "pg validate ok" || { echo "HTTP $code"; cat "$tmp"; warn "pg validate failed (airtravel may not exist)"; }
rm -f "$tmp" || true

read code tmp < <(curl_json POST /approve "{\"conn_id\":$PG_CONN_ID,\"sql\":\"select 1\",\"question\":\"pg smoke\"}")
[[ "$code" == "200" ]] && pass "pg approve ok" || { echo "HTTP $code"; cat "$tmp"; fail "pg approve failed"; }
rm -f "$tmp"

# safety gate (negative)
read code tmp < <(curl_json POST /preview "{\"conn_id\":$PG_CONN_ID,\"sql\":\"UPDATE xyz SET a=a\"}")
[[ "$code" != "200" ]] && pass "pg safety gate blocked non-SELECT" || { echo "Payload:"; cat "$tmp"; fail "pg safety gate did not block write"; }
rm -f "$tmp"

############################################
# 2) MySQL disposable external
############################################
echo "== MySQL connector smoke (disposable container) =="

docker rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$MYSQL_CONTAINER" -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=sample -p ${MYSQL_PORT}:3306 mysql:8 >/dev/null
echo "⏳ waiting for MySQL to be ready..."
for i in {1..40}; do
  if docker exec -i "$MYSQL_CONTAINER" mysqladmin -uroot -proot ping >/dev/null 2>&1; then break; fi
  sleep 1
  [[ $i -eq 40 ]] && fail "MySQL did not become ready"
done

docker exec -i "$MYSQL_CONTAINER" mysql -uroot -proot sample >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS air_small (month VARCHAR(10), y1958 INT, y1959 INT, y1960 INT);
DELETE FROM air_small;
INSERT INTO air_small VALUES 
 ('JAN',340,360,417),('FEB',318,342,391),('MAR',362,406,419),('APR',348,396,461),('MAY',363,420,472);
CREATE USER IF NOT EXISTS 'ro'@'%' IDENTIFIED BY 'ro';
GRANT SELECT ON sample.* TO 'ro'@'%';
FLUSH PRIVILEGES;
SQL

read code tmp < <(curl_json POST /connections "{\"name\":\"mysql-local\",\"driver\":\"mysql\",\"dsn\":\"$MYSQL_TEST_DSN\"}")
[[ "$code" == "200" ]] || { echo "HTTP $code"; cat "$tmp"; fail "POST /connections (mysql) failed"; }
MYSQL_CONN_ID=$(json_field "$tmp" 'j.get("id")'); rm -f "$tmp"
[[ -n "$MYSQL_CONN_ID" && "$MYSQL_CONN_ID" != "None" ]] || fail "Could not parse mysql connection id"

read code tmp < <(curl_json POST /connections/test "{\"conn_id\":$MYSQL_CONN_ID}")
[[ "$code" == "200" ]] && pass "mysql connection test ok" || { echo "HTTP $code"; cat "$tmp"; fail "mysql test failed"; }
rm -f "$tmp"

read code tmp < <(curl_json GET "/schema/cards?conn_id=$MYSQL_CONN_ID")
[[ "$code" == "200" ]] && pass "mysql schema/cards ok" || { echo "HTTP $code"; cat "$tmp"; fail "mysql schema/cards failed"; }
rm -f "$tmp"

read code tmp < <(curl_json POST /preview "{\"conn_id\":$MYSQL_CONN_ID,\"sql\":\"select count(*) from air_small\"}")
[[ "$code" == "200" ]] && pass "mysql preview ok" || { echo "HTTP $code"; cat "$tmp"; fail "mysql preview failed"; }
rm -f "$tmp"

read code tmp < <(curl_json POST /validate "{\"conn_id\":$MYSQL_CONN_ID,\"sql\":\"select * from air_small limit 3\"}")
[[ "$code" == "200" ]] && pass "mysql validate ok" || { echo "HTTP $code"; cat "$tmp"; warn "mysql validate returned non-200"; }
rm -f "$tmp" || true

read code tmp < <(curl_json POST /approve "{\"conn_id\":$MYSQL_CONN_ID,\"sql\":\"select * from air_small limit 3\",\"question\":\"mysql smoke\"}")
[[ "$code" == "200" ]] && pass "mysql approve ok" || { echo "HTTP $code"; cat "$tmp"; fail "mysql approve failed"; }
rm -f "$tmp"

# safety gate (negative)
read code tmp < <(curl_json POST /preview "{\"conn_id\":$MYSQL_CONN_ID,\"sql\":\"DELETE FROM air_small\"}")
[[ "$code" != "200" ]] && pass "mysql safety gate blocked DML" || { echo "Payload:"; cat "$tmp"; fail "mysql safety gate did not block write"; }
rm -f "$tmp"

# Cleanup MySQL container (comment if you want to keep it)
docker rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
pass "mysql disposable test cleaned up"

############################################
# 3) Snowflake optional
############################################
if [[ -n "$SNOWFLAKE_DSN" ]]; then
  echo "== Snowflake connector smoke =="
  read code tmp < <(curl_json POST /connections "{\"name\":\"snowflake\",\"driver\":\"snowflake\",\"dsn\":\"$SNOWFLAKE_DSN\"}")
  [[ "$code" == "200" ]] || { echo "HTTP $code"; cat "$tmp"; fail "POST /connections (snowflake) failed"; }
  SNOW_ID=$(json_field "$tmp" 'j.get("id")'); rm -f "$tmp"
  [[ -n "$SNOW_ID" && "$SNOW_ID" != "None" ]] || fail "Could not parse snowflake connection id"

  read code tmp < <(curl_json POST /connections/test "{\"conn_id\":$SNOW_ID}")
  [[ "$code" == "200" ]] && pass "snowflake connection test ok" || { echo "HTTP $code"; cat "$tmp"; fail "snowflake test failed"; }
  rm -f "$tmp"

  read code tmp < <(curl_json GET "/schema/cards?conn_id=$SNOW_ID")
  [[ "$code" == "200" ]] && pass "snowflake schema/cards ok" || { echo "HTTP $code"; cat "$tmp"; warn "snowflake schema/cards non-200"; }
  rm -f "$tmp" || true

  read code tmp < <(curl_json POST /preview "{\"conn_id\":$SNOW_ID,\"sql\":\"select current_database(), current_schema()\"}")
  [[ "$code" == "200" ]] && pass "snowflake preview ok" || { echo "HTTP $code"; cat "$tmp"; fail "snowflake preview failed"; }
  rm -f "$tmp"

  read code tmp < <(curl_json POST /validate "{\"conn_id\":$SNOW_ID,\"sql\":\"select 1\"}")
  [[ "$code" == "200" ]] && pass "snowflake validate ok (plan text expected)" || { echo "HTTP $code"; cat "$tmp"; warn "snowflake validate non-200"; }
  rm -f "$tmp" || true

  read code tmp < <(curl_json POST /approve "{\"conn_id\":$SNOW_ID,\"sql\":\"select 1\",\"question\":\"snowflake smoke\"}")
  [[ "$code" == "200" ]] && pass "snowflake approve ok" || { echo "HTTP $code"; cat "$tmp"; fail "snowflake approve failed"; }
  rm -f "$tmp"
else
  warn "SNOWFLAKE_DSN not set — skipping Snowflake test"
fi

echo
pass "All connector smoke tests completed"
