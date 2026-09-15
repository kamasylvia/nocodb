#!/bin/zsh
# f10r3l5_int.sh — lane5 F10 R3 收敛确认 int（nocodb-dev）
# CRUD 1 轮 + pg8000 DB 核验（含唯一索引）+ 权限 401/403 + update title 非串疑点实测
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMAIL_A="f10r3l5a_${TS}@ce-ee.local"
EMAIL_B="f10r3l5b_${TS}@ce-ee.local"
EMAIL_C="f10r3l5c_${TS}@ce-ee.local"
PASS="F10r3l5!pass1"
ISSUES=()
say() { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
JQ() { command jq "$@"; }
DBQ() { uv run --with pg8000 python3 "$REPO/.work/ee-ce/f10r3l5_db.py" qnap.elf-balance.ts.net "$DB_USER" "$DB_PASSWORD" "$@"; }
ERRLOG="$REPO/.work/ee-ce/logs/backend.log"

set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; esac; done <<< "$SECRETS"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || fail "Infisical DB 凭证拉取失败"
echo "db creds ok"

say "P0. 窗口前 ERROR 基线"
ERR_BEFORE=$(grep -c ' ERROR ' "$ERRLOG" 2>/dev/null || echo 0)
echo "ERROR baseline=$ERR_BEFORE"

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
B=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"f10r3l5_$TS\"}")
BID=$(echo "$B" | JQ -r '.id // empty'); [ -n "$BID" ] || fail "建 base: $B"
echo "base=$BID"

say "P3. 401 无 token（GET/POST/PATCH/DELETE）"
for M in GET POST; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X $M "$BASE_URL/api/v2/meta/bases/$BID/dashboards" -H 'Content-Type: application/json' -d '{"title":"x"}')
  [ "$CODE" = "401" ] || fail "$M 无 token 应 401 got $CODE"
done
echo "401 集合路由 ok（:id 路由 ExtractIdsMiddleware 鉴权前预查 404, 属上游模式; 真实 id 的 401 移至 P4b）"

say "P4. create（正常 + 校验面）"
D1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"F10 R3 L5 主板","description":"desc-1"}')
D1_ID=$(echo "$D1" | JQ -r '.id // empty'); [ -n "$D1_ID" ] || fail "create: $D1"
echo "$D1_ID" | grep -q '^dash' || fail "id 非 dash 前缀: $D1_ID"
[ "$(echo "$D1" | JQ -r '.title')" = "F10 R3 L5 主板" ] || fail "回显 title 不符: $D1"
D2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second"}')
D2_ID=$(echo "$D2" | JQ -r '.id // empty'); [ -n "$D2_ID" ] || fail "create 2: $D2"
# title 前后空白应 trim
DT=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"  trimmed-title  "}')
[ "$(echo "$DT" | JQ -r '.title')" = "trimmed-title" ] || fail "create trim: $DT"
DT_ID=$(echo "$DT" | JQ -r '.id')
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second"}')
[ "$C" = "400" ] || fail "dup 应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{}')
[ "$C" = "400" ] || fail "缺 title 应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":123}')
[ "$C" = "400" ] || fail "create title 非串应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"ok","description":42}')
[ "$C" = "400" ] || fail "desc 非串应 400 got $C"
LONG=$(printf 'L%.0s' {1..256})
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$C" = "400" ] || fail "title>255 应 400 got $C"
echo "create+validation ok ($D1_ID / $D2_ID / $DT_ID)"

say "P4b. 真实 id 无 token PATCH/DELETE 应 401"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" -H 'Content-Type: application/json' -d '{"title":"x"}')
[ "$CODE" = "401" ] || fail "PATCH 真实 id 无 token 应 401 got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID")
[ "$CODE" = "401" ] || fail "DELETE 真实 id 无 token 应 401 got $CODE"
echo "401 :id 路由 ok"

say "P5. list + get + 404"
L=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}")
LC=$(echo "$L" | JQ 'length')
[ "$LC" -ge 3 ] || fail "list 应 >=3 got $LC"
G=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" "${AUTH_A[@]}")
[ "$(echo "$G" | JQ -r '.id')" = "$D1_ID" ] || fail "get: $G"
C=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards/dashnonexist000" "${AUTH_A[@]}")
[ "$C" = "404" ] || fail "get 不存在应 404 got $C"
echo "list/get ok"

say "P6. patch（正常 + 校验面 + title 非串疑点）"
P=$(curl -sS -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"second-renamed","description":"d2"}')
[ "$(echo "$P" | JQ -r '.title')" = "second-renamed" ] || fail "patch 回显: $P"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"F10 R3 L5 主板"}')
[ "$C" = "400" ] || fail "patch 重名应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"   "}')
[ "$C" = "400" ] || fail "patch 空白应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$C" = "400" ] || fail "patch 超长应 400 got $C"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/dashnonexist000" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{"title":"x"}')
[ "$C" = "404" ] || fail "patch 不存在应 404 got $C"
echo "--- R2 疑点: patch title 非串（R2 前有 typeof 守卫，重构后疑似 500）---"
for BAD in '123' '{"a":1}' 'true' 'null' '["x"]'; do
  CODE=$(curl -sS -o /tmp/f10r3l5_patch_bad.json -w '%{http_code}' -X PATCH "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":$BAD}")
  BODYMSG=$(head -c 120 /tmp/f10r3l5_patch_bad.json)
  if [ "$CODE" = "400" ]; then
    echo "patch title=$BAD → 400 ok"
  else
    echo "ISSUE: patch title=$BAD → $CODE ($BODYMSG)"
    ISSUES+=("patch title=$BAD → $CODE 应 400")
  fi
done
echo "patch ok"

say "P7. DB 核验（行/回显/唯一索引）"
DBROW=$(DBQ dash "$D1_ID")
echo "$DBROW" | grep -qF 'F10 R3 L5 主板' || fail "DB 行 title 不符: $DBROW"
IDX=$(DBQ idx x)
echo "$IDX" | grep -q 'nc_dashboards_base_title_unique' || fail "唯一索引未建: $IDX"
echo "idx line: $(echo "$IDX" | JQ -r '.[] | select(.[0]=="nc_dashboards_base_title_unique") | .[1]')"
DBC=$(DBQ dashcount "$BID")
echo "db rows=$DBC"

say "P8. 注入/特殊字符回显"
XSS=$'\'<script>alert(1)</script>\'; DROP TABLE nc_dashboards_v2; -- "q"'
BODY=$(jq -n --arg t "$XSS" '{title:$t}')
INJ=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "$BODY")
INJ_ID=$(echo "$INJ" | JQ -r '.id // empty'); [ -n "$INJ_ID" ] || fail "注入 title create: $INJ"
[ "$(echo "$INJ" | JQ -r '.title')" = "$XSS" ] || fail "注入回显不一致"
sleep 1
DBROW=$(DBQ dash "$INJ_ID")
echo "$DBROW" | grep -qF '<script>alert(1)</script>' || fail "DB 未原样存储: $DBROW"
DBC2=$(DBQ dashcount "$BID")
echo "表存活核验 rows=$DBC2（>0 = DROP 未生效, 参数化确认）"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$INJ_ID" "${AUTH_A[@]}"
echo "injection echo ok"

say "P9. 权限：C 非成员 403；B editor 403"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards" "${AUTH_C[@]}")
[ "$CODE" = "403" ] || fail "C list 应 403 got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D1_ID" "${AUTH_C[@]}")
[ "$CODE" = "403" ] || fail "C get 应 403 got $CODE"
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
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$DT_ID" "${AUTH_A[@]}")
[ "$CODE" = "200" ] || fail "A delete DT 应 200 got $CODE"
echo "403 matrix ok"

say "P10. delete + DB 404 后置"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}"
sleep 1
DBD=$(DBQ dash "$D2_ID")
[ "$DBD" = "[]" ] || fail "D2 DB 行仍在: $DBD"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/dashboards/$D2_ID" "${AUTH_A[@]}")
[ "$CODE" = "404" ] || fail "删后 get 应 404 got $CODE"
echo "delete ok"

say "P11. base 删除联动"
BD=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID" "${AUTH_A[@]}")
[ "$BD" = "200" ] || fail "删 base: $BD"
sleep 2
DASHLEFT=$(DBQ dashcount_all "$BID")
echo "$DASHLEFT" | grep -q '^\[\[0\]\]\?$\|\[0\]' || fail "base 删后 dashboard 残留 $DASHLEFT"
echo "base-delete cascade ok"

say "P12. 窗口 ERROR 对比"
ERR_AFTER=$(grep -c ' ERROR ' "$ERRLOG" 2>/dev/null || echo 0)
echo "ERROR before=$ERR_BEFORE after=$ERR_AFTER delta=$((ERR_AFTER - ERR_BEFORE))"

echo
if [ "${#ISSUES[@]}" -gt 0 ]; then
  printf 'INT ISSUES (%d):\n' "${#ISSUES[@]}"
  printf '  - %s\n' "${ISSUES[@]}"
  exit 3
fi
echo "ALL PASS"
