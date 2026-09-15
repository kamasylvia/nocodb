#!/bin/zsh
# f05-e2e.sh — F05 Base Variables API 集成自测（连 nocodb-dev）
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f01e2e@ce-ee.local"
PASS="F01e2e!pass1"
RUN_TS=$(date +%s)

say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
command -v jq >/dev/null || fail "需要 jq"

CREATED_BASE=""
cleanup() {
  if [ -n "${CREATED_BASE:-}" ] && [ -n "${TOKEN:-}" ]; then
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$CREATED_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
  fi
}
trap cleanup EXIT

say "1. 登录"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
fi
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "no token"
AUTH=(-H "xc-auth: $TOKEN" -H 'Content-Type: application/json')

say "2. 建 base"
BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f05_e2e_$RUN_TS\"}")
CREATED_BASE=$(echo "$BASE" | jq -r '.id // empty')
[ -n "$CREATED_BASE" ] || fail "create base: $BASE"

say "3. 创建变量（text + secret + 非法 key）"
V1=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables" "${AUTH[@]}" -d '{"key":"API_ENDPOINT","value":"https://example.com","description":"demo","type":"text"}')
CODE=$(echo "$V1" | tail -1); echo "$V1" | head -1
[ "$CODE" = "200" ] || fail "create text var: $CODE"
VID1=$(echo "$V1" | head -1 | jq -r '.id')

V2=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables" "${AUTH[@]}" -d '{"key":"SECRET_KEY","value":"s3cr3t!","type":"secret"}')
CODE=$(echo "$V2" | tail -1)
[ "$CODE" = "200" ] || fail "create secret var: $CODE"
echo "secret created, list-mask check:"
LIST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables" "${AUTH[@]}")
MASKED=$(echo "$LIST" | jq -r '.[] | select(.key=="SECRET_KEY") | (.value // "MASKED" | if . == "" then "MASKED" else . end)')
[ "$MASKED" = "MASKED" ] || fail "secret not masked in list: $MASKED"
echo "secret masked in list OK"

BADKEY=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables" "${AUTH[@]}" -d '{"key":"bad-key","value":"x"}')
CODE=$(echo "$BADKEY" | tail -1)
[ "$CODE" = "400" ] || fail "lowercase key should 400: $CODE"

DUPKEY=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables" "${AUTH[@]}" -d '{"key":"API_ENDPOINT","value":"y"}')
CODE=$(echo "$DUPKEY" | tail -1)
[ "$CODE" = "400" ] || fail "dup key should 400: $CODE"

say "4. 读单条（secret 解密）+ 更新"
SEC=$(curl -sS "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID1" "${AUTH[@]}")
echo "$SEC"
[ "$(echo "$SEC" | jq -r '.value')" = "https://example.com" ] || fail "get var value mismatch"
UPD=$(curl -sS -w '\n%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID1" "${AUTH[@]}" -d '{"value":"https://changed.example.com"}')
CODE=$(echo "$UPD" | tail -1)
[ "$CODE" = "200" ] && [ "$(echo "$UPD" | head -1 | jq -r '.value')" = "https://changed.example.com" ] || fail "update var: $CODE"

KEYLOCK=$(curl -sS -w '\n%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID1" "${AUTH[@]}" -d '{"key":"RENAMED"}')
CODE=$(echo "$KEYLOCK" | tail -1)
[ "$CODE" = "400" ] || fail "key rename should 400: $CODE"

say "4b. secret 二次读稳定性（缓存双重解密回归守卫）"
VID2=$(echo "$V2" | head -1 | jq -r '.id')
SEC2=$(curl -sS "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID2" "${AUTH[@]}")
V2V=$(echo "$SEC2" | jq -r '.value')
[ "$V2V" = "s3cr3t!" ] || fail "secret second-read broken (cache double-decrypt?): $V2V"
SEC3=$(curl -sS "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID2" "${AUTH[@]}")
[ "$(echo "$SEC3" | jq -r '.value')" = "s3cr3t!" ] || fail "secret third-read broken"

say "5. 删除 + 确认消失"
curl -sS -o /dev/null -w 'delete → %{http_code}\n' -X DELETE "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID1" "${AUTH[@]}"
GONE=$(curl -sS -w '\n%{http_code}' "$BASE_URL/api/v2/meta/bases/$CREATED_BASE/variables/$VID1" "${AUTH[@]}")
CODE=$(echo "$GONE" | tail -1)
echo "$CODE" | grep -qE '^4' || fail "deleted var should 404: $CODE"

say "6. 清理（base 删除 + trap 兜底）"
curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$CREATED_BASE" "${AUTH[@]}" -o /dev/null -w 'delete base → %{http_code}\n'
CREATED_BASE=""

say "F05 E2E PASS"
