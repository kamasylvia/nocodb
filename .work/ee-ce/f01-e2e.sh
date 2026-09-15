#!/bin/zsh
# f01-e2e.sh — F01 Unique values only API 集成自测（连 nocodb-dev）
# 前置: 后端 dev server 已跑在 :8080 (dev-backend.sh start)
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f01e2e@ce-ee.local"
PASS="F01e2e!pass1"
RUN_TS=$(date +%s)
JQ() { command jq "$@"; }

say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# 失败时也清理已建资源（rev-c 建议）
CREATED_BASE=""
cleanup() {
  if [ -n "${CREATED_BASE:-}" ] && [ -n "${TOKEN:-}" ]; then
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$CREATED_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
  fi
}
trap cleanup EXIT

command -v jq >/dev/null || fail "需要 jq"

say "1. 等后端就绪"
for i in $(seq 1 120); do
  curl -sf "$BASE_URL/" -o /dev/null 2>/dev/null && break
  [ "$i" = 120 ] && fail "后端 8080 未就绪"
  sleep 2
done
echo "backend up"

say "2. 登录 (signup 或 login)"
SIGNUP=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
TOKEN=$(echo "$SIGNUP" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty' )
fi
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "拿不到 token: $SIGNUP"
AUTH=(-H "xc-auth: $TOKEN")
echo "token ok"

say "3. 建 base + table（列带 unique:true）"
BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"f01_e2e_$RUN_TS\"}")
BASE_ID=$(echo "$BASE" | jq -r '.id // empty')
[ -n "$BASE_ID" ] || fail "建 base 失败: $BASE"
CREATED_BASE="$BASE_ID"

TABLE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BASE_ID/tables" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{
  \"table_name\":\"uniq_$RUN_TS\",
  \"columns\":[
    {\"title\":\"Title\",\"uidt\":\"SingleLineText\",\"column_name\":\"title\",\"unique\":true},
    {\"title\":\"Num\",\"uidt\":\"Number\",\"column_name\":\"num\"}
  ]
}")
TABLE_ID=$(echo "$TABLE" | jq -r '.id // empty')
[ -n "$TABLE_ID" ] || fail "建 table 失败: $TABLE"
TITLE_COL=$(echo "$TABLE" | jq -r '.columns[] | select(.title=="Title") | .id')
UNIQ_FLAG=$(echo "$TABLE" | jq -r '.columns[] | select(.title=="Title") | .unique')
echo "table=$TABLE_ID title_col=$TITLE_COL unique_flag=$UNIQ_FLAG"
[ "$UNIQ_FLAG" = "true" ] || fail "建列时 unique 未生效"

say "4. 插入首条 + 重复条（重复必须报错）"
R1=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/tables/$TABLE_ID/records" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Title":"dup-me"}')
CODE=$(echo "$R1" | tail -1)
echo "$R1" | head -1
[ "$CODE" = "200" ] || fail "首条插入应成功, got $CODE"

R2=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/tables/$TABLE_ID/records" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Title":"dup-me"}')
CODE=$(echo "$R2" | tail -1)
BODY=$(echo "$R2" | head -1)
echo "dup insert → $CODE: $(echo "$BODY" | head -c 200)"
echo "$CODE" | grep -qE '^(4|5)' || fail "重复插入应失败, got $CODE"

say "5. 关 unique → 重复插入应成功"
UPD=$(curl -sS -w '\n%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/columns/$TITLE_COL" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"title":"Title","unique":false}')
CODE=$(echo "$UPD" | tail -1)
[ "$CODE" = "200" ] || fail "关 unique 失败: $(echo "$UPD" | head -1)"

R3=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/tables/$TABLE_ID/records" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Title":"dup-me"}')
CODE=$(echo "$R3" | tail -1)
[ "$CODE" = "200" ] || fail "关 unique 后重复插入应成功, got $CODE"

say "6. 重开 unique（已有重复值应被拒）"
UPD2=$(curl -sS -w '\n%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/columns/$TITLE_COL" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"title":"Title","unique":true}')
CODE=$(echo "$UPD2" | tail -1)
BODY=$(echo "$UPD2" | head -1)
echo "re-enable → $CODE: $(echo "$BODY" | head -c 200)"
echo "$CODE" | grep -qE '^4' || fail "存在重复值时重开 unique 应失败, got $CODE"

say "7. 清理"
curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$BASE_ID" "${AUTH[@]}" -o /dev/null -w 'delete base → %{http_code}\n'

say "F01 E2E PASS"
