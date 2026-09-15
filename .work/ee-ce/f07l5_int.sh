#!/bin/zsh
# f07l5_int.sh — lane5 F07 快照安全全链路交叉抽验（nocodb-dev）
# 链路: secret 变量源 base → 快照 → restore 产物 → 删除；每步 DB 核验 + 权限抽查
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMAIL_A="f07l5a_${TS}@ce-ee.local"
EMAIL_B="f07l5b_${TS}@ce-ee.local"
EMAIL_C="f07l5c_${TS}@ce-ee.local"
PASS="F07l5!pass1"
SECRET_VAL="s3cr3t-lane5-${TS}"
DBQ() { uv run --with pg8000 python3 "$REPO/.work/ee-ce/f07l5_db.py" qnap.elf-balance.ts.net "$DB_USER" "$DB_PASSWORD" "$@"; }
say() { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
JQ() { command jq "$@"; }
CUR jobs_failed_before > /dev/null 2>&1 || true

# --- DB 凭证（Infisical KDL，运行时拉取不落盘） ---
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOKEN_INF=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOKEN_INF" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do
  case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; esac
done <<< "$SECRETS"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || fail "Infisical DB 凭证拉取失败"
echo "db creds ok"

say "P0. 日志基线（JOB FAILED 计数）"
LOG="$REPO/.work/ee-ce/logs/backend.log"
JOB_FAILED_BEFORE=$(grep -c "JOB FAILED" "$LOG" || true)
echo "job_failed_before=$JOB_FAILED_BEFORE"

say "P1. 认证：user A signup/signin；user B/C signup（B 后续 editor，C 非成员）"
TOKEN_A=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_A" ] || TOKEN_A=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_A\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_A" ] && [ "$TOKEN_A" != "null" ] || fail "user A 拿不到 token"
AUTH_A=(-H "xc-auth: $TOKEN_A")
PR=$(DBQ promote "$EMAIL_A")
echo "promote A: $PR"
echo "$PR" | grep -q "workspace-level-creator" || fail "user A 提权失败: $PR"
TOKEN_B=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_B" ] || TOKEN_B=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_B" ] && [ "$TOKEN_B" != "null" ] || fail "user B 拿不到 token"
AUTH_B=(-H "xc-auth: $TOKEN_B")
TOKEN_C=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_C" ] || TOKEN_C=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_C\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
[ -n "$TOKEN_C" ] && [ "$TOKEN_C" != "null" ] || fail "user C 拿不到 token"
AUTH_C=(-H "xc-auth: $TOKEN_C")
echo "tokens ok"

say "P2. 建源 base + table + 2 行数据"
SRC=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"f07l5_src_$TS\"}")
SRC_ID=$(echo "$SRC" | JQ -r '.id // empty'); [ -n "$SRC_ID" ] || fail "建 base 失败: $SRC"
TABLE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/tables" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"table_name\":\"t_$TS\",\"columns\":[{\"title\":\"Title\",\"uidt\":\"SingleLineText\"}]}")
TABLE_ID=$(echo "$TABLE" | JQ -r '.id // empty'); [ -n "$TABLE_ID" ] || fail "建 table 失败: $TABLE"
for i in 1 2; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/tables/$TABLE_ID/records" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"Title\":\"row$i\"}")
  [ "$CODE" = "200" ] || fail "插行失败 $CODE"
done
echo "src base=$SRC_ID table=$TABLE_ID"

say "P3. secret 变量写入"
VAR=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/variables" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"key\":\"L5_SECRET\",\"value\":\"$SECRET_VAL\",\"type\":\"secret\"}")
VAR_ID=$(echo "$VAR" | JQ -r '.id // empty'); [ -n "$VAR_ID" ] || fail "建变量失败: $VAR"
sleep 1
VARS_SRC=$(DBQ vars "$SRC_ID")
echo "src vars row: $VARS_SRC"
[ "$(echo "$VARS_SRC" | JQ -r '.[0][0]')" -ge 1 ] || fail "源 base 变量行缺失"
echo "$VARS_SRC" | grep -q "$SECRET_VAL" && fail "源变量明文落库（应密文）"
echo "src secret stored (non-plaintext) ok"

say "P4. 无 token 访问 snapshots → 401"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots")
[ "$CODE" = "401" ] || fail "无 token GET snapshots 应 401, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" -H 'Content-Type: application/json' -d '{}')
[ "$CODE" = "401" ] || fail "无 token POST snapshots 应 401, got $CODE"
echo "401 ok"

say "P5. 建快照"
SNAP_RES=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{}')
echo "$SNAP_RES" | head -c 400; echo
SNAP_ID=$(echo "$SNAP_RES" | JQ -r '.id // empty')
SNAP_BASE_ID=$(echo "$SNAP_RES" | JQ -r '.snapshot_base_id // empty')
[ -n "$SNAP_ID" ] && [ -n "$SNAP_BASE_ID" ] || fail "建快照失败: $SNAP_RES"
sleep 1
DB_SNAP=$(DBQ snaps "$SRC_ID")
echo "db snapshot row: $DB_SNAP"
echo "$DB_SNAP" | grep -q "$SNAP_ID" || fail "nc_snapshots 无行"
echo "$DB_SNAP" | grep -q "$SNAP_BASE_ID" || fail "snapshot_base_id 不符"
DB_COPY0=$(DBQ base "$SNAP_BASE_ID")
echo "copy base row(early): $DB_COPY0"

say "P6. 轮询至 completed（上限 ~90s）"
FINAL=""
for i in $(seq 1 30); do
  sleep 3
  ONE=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH_A[@]}")
  ST=$(echo "$ONE" | JQ -r '.status // empty')
  echo "poll $i: $ST"
  if [ "$ST" = "completed" ] || [ "$ST" = "error" ]; then FINAL="$ST"; break; fi
done
[ "$FINAL" = "completed" ] || fail "快照未 completed, got ${FINAL:-timeout}: $ONE"
DB_COPY=$(DBQ base "$SNAP_BASE_ID")
echo "copy base row: $DB_COPY"
[ "$(echo "$DB_COPY" | JQ -r '.[0][3]')" = "false" ] || fail "副本 base 不应 deleted: $DB_COPY"

say "P7. 副本 base 无变量行（无 secret 物料通道）"
VARS_COPY=$(DBQ vars "$SNAP_BASE_ID")
echo "copy vars row: $VARS_COPY"
[ "$(echo "$VARS_COPY" | JQ -r '.[0][0]')" = "0" ] || fail "副本 base 出现变量行: $VARS_COPY"

say "P8. restore → 新 base"
RESTORE_RES=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID/restore" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d '{}')
echo "$RESTORE_RES"; echo
RESTORED_ID=$(echo "$RESTORE_RES" | JQ -r '.base_id // empty'); [ -n "$RESTORED_ID" ] || fail "restore 失败: $RESTORE_RES"
sleep 1
DB_RESTORED=$(DBQ base "$RESTORED_ID")
echo "restored base row: $DB_RESTORED"
echo "$DB_RESTORED" | grep -q "f07l5_src_$TS (restored)" || fail "restore 产物 title 不符: $DB_RESTORED"
VARS_RESTORED=$(DBQ vars "$RESTORED_ID")
echo "restored vars row: $VARS_RESTORED"
[ "$(echo "$VARS_RESTORED" | JQ -r '.[0][0]')" = "0" ] || fail "restore 产物出现变量行: $VARS_RESTORED"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$RESTORED_ID" "${AUTH_A[@]}")
[ "$CODE" = "200" ] || fail "restore 产物 API 读失败 $CODE"

say "P9. editor 角色 403 抽查（user B → editor）"
INV=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/users" "${AUTH_A[@]}" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_B\",\"roles\":\"editor\"}")
echo "$INV"
CODE=$(echo "$INV" | tail -1)
[ "$CODE" = "200" ] || fail "invite editor 失败: $INV"
sleep 1
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH_B[@]}")
[ "$CODE" = "403" ] || fail "editor GET snapshots 应 403, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH_B[@]}" -H 'Content-Type: application/json' -d '{}')
[ "$CODE" = "403" ] || fail "editor POST snapshots 应 403, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID/restore" "${AUTH_B[@]}" -H 'Content-Type: application/json' -d '{}')
[ "$CODE" = "403" ] || fail "editor restore 应 403, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH_B[@]}")
[ "$CODE" = "403" ] || fail "editor delete 应 403, got $CODE"
echo "editor 403 x4 ok"

say "P10. 非成员抽查：user C（无 base/workspace 角色）读快照"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH_C[@]}")
echo "non-member list → $CODE"
case "$CODE" in 401|403|404) ;; *) fail "非成员 list 快照应 401/403/404, got $CODE";; esac
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH_C[@]}")
echo "non-member get → $CODE"
case "$CODE" in 401|403|404) ;; *) fail "非成员 get 快照应 401/403/404, got $CODE";; esac

say "P11. 删快照 → 登记行删 + 副本 soft-delete"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH_A[@]}")
[ "$CODE" = "200" ] || fail "删快照失败 $CODE"
sleep 1
DB_SNAP2=$(DBQ snaps "$SRC_ID")
echo "db snapshots after delete: $DB_SNAP2"
[ "$(echo "$DB_SNAP2" | JQ --arg sid "$SNAP_ID" '[.[] | select(.[0]==$sid)] | length')" = "0" ] || fail "nc_snapshots 行未删"
DB_COPY2=$(DBQ base "$SNAP_BASE_ID")
echo "copy base after delete: $DB_COPY2"
[ "$(echo "$DB_COPY2" | JQ -r '.[0][3]')" = "true" ] || fail "副本 base 未 soft-delete: $DB_COPY2"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH_A[@]}")
[ "$CODE" = "404" ] || fail "已删快照 GET 应 404, got $CODE"

say "P12. 清理资源 + 日志增量核验"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$RESTORED_ID" "${AUTH_A[@]}" || true
# 源 base 最后删（其 snapshot 注册行已空，cleanup 空转路径）
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID" "${AUTH_A[@]}" || true
sleep 2
JOB_FAILED_AFTER=$(grep -c "JOB FAILED" "$LOG" || true)
echo "job_failed before=$JOB_FAILED_BEFORE after=$JOB_FAILED_AFTER"
if [ "$JOB_FAILED_AFTER" -gt "$JOB_FAILED_BEFORE" ]; then
  echo "NOTE: 本链路期间新增 JOB FAILED（检查是否并发噪音）"
fi

printf '\n== LANE5 INT ALL PASS ==\n'
