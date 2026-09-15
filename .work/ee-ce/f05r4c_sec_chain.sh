#!/bin/zsh
# f05r4c_sec_chain.sh — R4 rev-c 安全终审: secret 全链路实测
# 创建 secret 变量 → DB(nocodb-dev) 直查密文 → API 解密回读 → base 删除后 0 残留
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f01e2e@ce-ee.local"
PASS="F01e2e!pass1"
RUN_TS=$(date +%s)
MARKER="r4c-secret-${RUN_TS}-Zq9!x"
DBQ="/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f05r3b_dbq.py"
WORK="/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
command -v jq >/dev/null || fail "需要 jq"

# --- 凭证: Infisical KDL DB_* (运行时拉取, 不落盘; 严禁 nocodb 生产库) ---
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
[ -n "$TOKEN" ] || fail "infisical login failed"
SECRETS=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do
  case "$k" in
    DB_USER) DB_USER="$v";;
    DB_PASSWORD) DB_PASSWORD="$v";;
  esac
done <<< "$SECRETS"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || fail "未取到 DB 凭证"
export FDB_HOST="qnap.elf-balance.ts.net" FDB_PORT="5432" FDB_USER="$DB_USER" FDB_PASSWORD="$DB_PASSWORD"

echo "== 1. 登录 (既有 creator 账号 $EMAIL) =="
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "no token"
AUTH=(-H "xc-auth: $TOKEN" -H 'Content-Type: application/json')

echo "== 2. 建 base =="
BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f05r4c_$RUN_TS\"}")
BID=$(echo "$BASE" | jq -r '.id // empty')
[ -n "$BID" ] || fail "create base: $BASE"
echo "base=$BID"

echo "== 3. 创建 secret 变量 (marker 唯一明文) =="
V=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/variables" "${AUTH[@]}" -d "{\"key\":\"R4C_SECRET\",\"value\":\"$MARKER\",\"type\":\"secret\"}")
CODE=$(echo "$V" | tail -1)
[ "$CODE" = "200" ] || fail "create secret: $CODE $(echo "$V" | head -1)"
VID=$(echo "$V" | head -1 | jq -r '.id')
echo "var id=$VID"

echo "== 4. DB 直查: nc_base_variables.value 必须是密文 =="
DBROW=$(cd "$WORK" && uv run --with pg8000 python3 "$DBQ" "SELECT key, type, value FROM nc_base_variables WHERE id = '$VID'" --one)
echo "$DBROW" | head -c 300; echo
DBVAL=$(echo "$DBROW" | jq -r '.value // ""')
[ "$DBVAL" != "$MARKER" ] || fail "DB 存明文! 加密链路断裂"
[ -n "$DBVAL" ] || fail "DB 行 value 为空"
case "$DBVAL" in
  *"$MARKER"*) fail "DB 密文中包含明文 marker";;
esac
echo "DB 密文前缀: $(printf '%s' "$DBVAL" | head -c 24)... (≠明文 ✓)"

echo "== 5. list 掩码 + get 解密回读 =="
LIST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/variables" "${AUTH[@]}")
LV=$(echo "$LIST" | jq -r '.[] | select(.key=="R4C_SECRET") | (.value // "MASKED" | if . == "" then "MASKED" else . end)')
[ "$LV" = "MASKED" ] || fail "list 未掩码: $LV"
echo "list 掩码 OK"
SEC=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/variables/$VID" "${AUTH[@]}")
[ "$(echo "$SEC" | jq -r '.value')" = "$MARKER" ] || fail "get 解密回读不等: $SEC"
echo "get 解密回读 OK (二次:"
SEC2=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/variables/$VID" "${AUTH[@]}")
[ "$(echo "$SEC2" | jq -r '.value')" = "$MARKER" ] || fail "二次读异常(缓存双重解密?)"
echo "二次读 OK)"

echo "== 6. base 删除 → DB 0 残留 =="
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$BID" "${AUTH[@]}"
sleep 1
RES=$(cd "$WORK" && uv run --with pg8000 python3 "$DBQ" "SELECT count(*) AS n FROM nc_base_variables WHERE base_id = '$BID'" --one)
N=$(echo "$RES" | jq -r '.n')
[ "$N" = "0" ] || fail "base 删除后残留 $N 行"
echo "残留 0 行 ✓"

echo "== F05 R4 rev-c 安全全链路 PASS =="
