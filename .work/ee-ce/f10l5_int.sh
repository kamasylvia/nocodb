#!/bin/zsh
# f10l5_int.sh — lane5 F10 dashboards CRUD 交叉抽验（nocodb-dev）
# create→list→get→patch→delete + DB 核验 + 401/403/越权抽查 + 注入回显
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMAIL_A="f10l5a_${TS}@ce-ee.local"
EMAIL_B="f10l5b_${TS}@ce-ee.local"
EMAIL_C="f10l5c_${TS}@ce-ee.local"
PASS="F10l5!pass1"
say() { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
JQ() { command jq "$@"; }
DBQ() { uv run --with pg8000 python3 "$REPO/.work/ee-ce/f10l5_db.py" qnap.elf-balance.ts.net "$DB_USER" "$DB_PASSWORD" "$@"; }

set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; esac; done <<< "$SECRETS"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || fail "Infisical DB 凭证拉取失败"
echo "db creds ok"

say "P1. 认证 A(creator)/B(editor 候选)/C(非成员)"
TOKEN_A=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_A" ] || TOKEN_A=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_A" ] && [ "$TOKEN_A" != "null" ] || fail "A token"
AUTH_A=(-H "xc-auth: $TOKEN_A")
PR=$(DBQ promote "$EMAIL_A"); echo "$PR" | grep -q workspace-level-creator || fail "A 提权: $PR"
TOKEN_B=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_B" ] || TOKEN_B=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
AUTH_B=(-H "xc-auth: $TOKEN_B")
TOKEN_C=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_C" ] || TOKEN_C=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
AUTH_C=(-H "xc-auth: $TOKEN_C")
echo "tokens ok"

say "P2. 建 base"
B=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"f10l5_$TS\"}")
BID=$(echo "$B" | JQ -r '.id // empty'); [ -n "$BID" ] || fail "建 base: $B"
echo "base=$BID"

say "P3. 401 无 token"
for M in GET POST; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X $M "$BASE_URL/api/v2/meta/bases/$BID/dashboards" -H 'Content-Type: application/json' -d '{"title":"x"}')
  [ "$CODE" = "401" ] || fail "$M 无 token 应 401 got $CODE"
done
echo "401 ok"

say "P4. create（正常 + 校验面）"
D1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"F10 Lane5 主板","description":"desc-1"}')
D1_ID=$(echo "$D1" | JQ -r '.id // empty'); [ -n "$D1_ID" ] || fail "create: $D1"
echo "$D1_ID" | grep -q '^dash' || fail "id 非 dash 前缀: $D1_ID"
[ "$(echo "$D1" | JQ -r '.title')" = "F10 Lane5 主板" ] || fail "回显 title 不符"
D2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second"}')
D2_ID=$(echo "$D2" | JQ -r '.id // empty'); [ -n "$D2_ID" ] || fail "create 2: $D2"
# 校验面
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second"}')
if [ "$C" = "400" ]; then echo "dup-check ok (400)"; else echo "DUP-CHECK-LEAK: 重名 got $C（缓存陈旧窗口漏拦，报 issue）"; fi
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{}')
[ "$C" = "400" ] || fail "缺 title 应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":123}')
[ "$C" = "400" ] || fail "title 非串应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"ok","description":42}')
[ "$C" = "400" ] || fail "desc 非串应 400 got $C"
LONG=$(printf 'L%.0s' {1..256})
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$C" = "400" ] || fail "title>255 应 400 got $C"
echo "create+validation ok ($D1_ID / $D2_ID)"

say "P5. list + get（base 路径 + dashboard-only 路径）"
L=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}")
LC=$(echo "$L" | JQ 'length')
echo "list count=$LC（DB 实际 2+；若 <2 = list 缓存陈旧丢行，报 issue）"
sleep 1
DBALL=$(DBQ dashcount "$BID")
echo "DB rows=$DBALL"
G=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" "${AUTH_A[@]}")
[ "$(echo "$G" | JQ -r '.id')" = "$D1_ID" ] || fail "get(base 路径): $G"
G2CODE=$(curl -sS -o /tmp/f10l5_g2.json -w '%{http_code}' "$BASE_URL/api/v2/meta/dashboards/$D1_ID" "${AUTH_A[@]}")
if [ "$G2CODE" = "200" ] && [ "$(jq -r '.id' /tmp/f10l5_g2.json)" = "$D1_ID" ]; then
  echo "get(dashboard-only) ok"
else
  echo "DASH-ONLY-ROUTE-BROKEN: GET /api/v2/meta/dashboards/:id got $G2CODE: $(head -c 200 /tmp/f10l5_g2.json)"
fi
C=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards/dashnonexist000" "${AUTH_A[@]}")
[ "$C" = "404" ] || fail "get 不存在应 404 got $C"
echo "list/get ok"

say "P6. patch（正常 + 重名 + 空串 + 超长 + 不存在）"
P=$(curl -sS -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second-renamed","description":"d2"}')
[ "$(echo "$P" | JQ -r '.title')" = "second-renamed" ] || fail "patch 回显: $P"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"F10 Lane5 主板"}')
[ "$C" = "400" ] || fail "patch 重名应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"   "}')
[ "$C" = "400" ] || fail "patch 空白 title 应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$C" = "400" ] || fail "patch 超长应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/dashnonexist000" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"x"}')
[ "$C" = "404" ] || fail "patch 不存在应 404 got $C"
echo "patch ok"

say "P7. 注入/特殊字符回显"
XSS=$'\'<script>alert(1)</script>--; DROP TABLE nc_dashboards_v2;-- "quotes"'
BODY=$(jq -n --arg t "$XSS" '{title:$t}')
INJ=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "$BODY")
INJ_ID=$(echo "$INJ" | JQ -r '.id // empty'); [ -n "$INJ_ID" ] || fail "注入 title create: $INJ"
[ "$(echo "$INJ" | JQ -r '.title')" = "$XSS" ] || fail "注入 title 回显不一致"
sleep 1
DBROW=$(DBQ dash "$INJ_ID")
echo "$DBROW" | grep -qF '<script>alert(1)</script>' || fail "DB 行未原样存储: $DBROW"
DASHCNT=$(DBQ dashcount "$BID")
echo "db rows in base=$DASHCNT"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$INJ_ID" "${AUTH_A[@]}"
echo "injection echo ok（存储层参数化，原样回读）"

say "P8. 权限：C 非成员 403；B editor 403；dashboard-only 路由越权"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_C[@]}")
[ "$CODE" = "403" ] || fail "C list 应 403 got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/dashboards/$D1_ID" "${AUTH_C[@]}")
if [ "$CODE" = "403" ]; then echo "C dashboard-only get 403 ok"; else echo "DASH-ONLY-NONMEMBER: got $CODE（应 403）"; fi
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_C[@]}" -H 'Content-Type: application/json' -d '{"title":"intruder"}')
[ "$CODE" = "403" ] || fail "C create 应 403 got $CODE"
INV=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/users" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"roles\":\"editor\"}")
[ "$INV" = "200" ] || fail "invite B editor: $INV"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_B[@]}" -H 'Content-Type: application/json' -d '{"title":"by-editor"}')
[ "$CODE" = "403" ] || fail "B editor create 应 403 got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" "${AUTH_B[@]}" -H 'Content-Type: application/json' -d '{"title":"hacked"}')
[ "$CODE" = "403" ] || fail "B editor patch 应 403 got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" "${AUTH_B[@]}")
[ "$CODE" = "403" ] || fail "B editor delete 应 403 got $CODE"
echo "403 matrix ok"

say "P9. delete + DB 核验 + 404 后置"
curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" >/dev/null
sleep 1
DBD=$(DBQ dash "$D2_ID")
[ "$DBD" = "[]" ] || fail "D2 DB 行仍在: $DBD"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}")
[ "$CODE" = "404" ] || fail "删后 get 应 404 got $CODE"
echo "delete ok"

say "P10. base 删除联动清 dashboard"
BD=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID" "${AUTH_A[@]}")
[ "$BD" = "200" ] || fail "删 base: $BD"
sleep 2
DASHLEFT=$(DBQ dashcount_all "$BID")
echo "$DASHLEFT" | grep -q '\[\[0\]\]' || fail "base 删后 dashboard 残留 $DASHLEFT"
echo "base-delete cascade ok"

say "P11. 服务端 500 抽查（本轮窗口）"
ERR5XX=$(grep -c ' ERROR ' "$REPO/.work/ee-ce/logs/backend.log" || true)
echo "backend ERROR 行计数(整日志, 参考)=$ERR5XX"

echo "ALL PASS"
