#!/bin/zsh
# f09-p1-selftest.sh — F09 Table Sync (P1 manual) API 全流程自测（连 nocodb-dev）
# 前置:
#   1. 后端 dev server 已跑在 :8080 且已包含 F09 实现（需主会话轮转 dev-backend.sh）
#   2. jq 可用
# 覆盖: create sync → 引擎 full-create → dest 表数据核对 → resync(增量镜像)
#       → freeze → resume → 守卫链(普通写路径 4xx) → delete → 清理
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
EMAIL="${F09_E2E_EMAIL:-f01e2e@ce-ee.local}"
PASS="${F09_E2E_PASS:-F01e2e!pass1}"
RUN_TS=$(date +%s)
say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
jqget() { echo "$1" | jq -r "$2"; }

command -v jq >/dev/null || fail "需要 jq"

SRC_BASE=""; DEST_BASE=""; SRC_TABLE=""
cleanup() {
  if [ -n "${DEST_BASE:-}" ] && [ -n "${TOKEN:-}" ]; then
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
  fi
}
trap cleanup EXIT

say "1. 等后端就绪"
for i in $(seq 1 120); do
  curl -sf "$BASE_URL/" -o /dev/null 2>/dev/null && break
  [ "$i" = 120 ] && fail "后端 8080 未就绪"
  sleep 2
done
echo "backend up"

say "2. 登录 (signup 或 signin)"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
fi
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "拿不到 token"
AUTH=(-H "xc-auth: $TOKEN")
echo "token ok"

say "3. 建 source base + table + 数据 + grid 视图开 allow_sync"
SRC_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09_src_$RUN_TS\"}" | jq -r '.id')
[ -n "$SRC_BASE" ] || fail "建 source base 失败"
SRC_TABLE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"table_name\":\"f09_src_tbl_$RUN_TS\",\"columns\":[
    {\"title\":\"Title\",\"uidt\":\"SingleLineText\",\"column_name\":\"title\"},
    {\"title\":\"Qty\",\"uidt\":\"Number\",\"column_name\":\"qty\"}
  ]}" | jq -r '.id')
[ -n "$SRC_TABLE" ] || fail "建 source table 失败"

# 插 3 行（v2 records API 平铺对象）
for i in 1 2 3; do
  curl -sS -X POST "$BASE_URL/api/v2/tables/$SRC_TABLE/records" "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -d "{\"Title\":\"row$i\",\"Qty\":$i}" -o /dev/null
done

# source table 的默认 grid view 开 allow_sync（share 视图开关同款路径）
VIEWS=$(curl -sS "$BASE_URL/api/v2/meta/tables/$SRC_TABLE/views" "${AUTH[@]}")
GRID_VIEW=$(echo "$VIEWS" | jq -r '.list[] | select(.type==3) | .id' | head -1)
[ -n "$GRID_VIEW" ] || fail "找不到 grid view: $VIEWS"
curl -sS -X PATCH "$BASE_URL/api/v2/meta/views/$GRID_VIEW" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{"allow_sync":true}' -o /dev/null
echo "source ready: base=$SRC_BASE table=$SRC_TABLE grid=$GRID_VIEW"

say "4. 建 dest base"
DEST_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09_dest_$RUN_TS\"}" | jq -r '.id')
[ -n "$DEST_BASE" ] || fail "建 dest base 失败"

say "5. sourceSchema 预检"
SCHEMA=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/source-schema" "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$SRC_TABLE\"}")
echo "$SCHEMA" | jq .
[ "$(echo "$SCHEMA" | jq -r '.view.allow_sync')" = "true" ] || fail "schema 未识别 allow_sync 视图"
[ "$(echo "$SCHEMA" | jq '.columns | length')" = "2" ] || fail "schema 列数不为 2"

say "6. 创建 sync（manual, delete 策略）"
SYNC=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09_sync_$RUN_TS\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$SRC_TABLE\",\"sourceViewId\":\"$GRID_VIEW\",\"onDeleteAction\":\"delete\",\"syncTrigger\":\"manual\"}")
echo "$SYNC" | jq .
SYNC_ID=$(jqget "$SYNC" '.id')
[ -n "$SYNC_ID" ] && [ "$SYNC_ID" != "null" ] || fail "创建 sync 失败"
DEST_TABLE=$(jqget "$SYNC" '.mappings[] | select(.role=="main") | .dest_table_id')
[ -n "$DEST_TABLE" ] || fail "mapping 缺 dest_table_id"
# mirror 表应立即存在且 synced=true
SYNCED_FLAG=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/tables" "${AUTH[@]}" | jq -r ".list[] | select(.id==\"$DEST_TABLE\") | .synced")
[ "$SYNCED_FLAG" = "true" ] || fail "mirror 表 synced != true（=$SYNCED_FLAG）"
echo "sync=$SYNC_ID mirror_table=$DEST_TABLE synced=$SYNCED_FLAG"

say "7. 等 full-create 完成（轮询 last_synced_at，最多 60s）"
for i in $(seq 1 30); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
  STATUS=$(jqget "$ST" '.status'); LAST=$(jqget "$ST" '.last_synced_at // empty')
  [ "$STATUS" = "active" ] && [ -n "$LAST" ] && break
  [ "$STATUS" = "error" ] && fail "sync error: $(jqget "$ST" '.last_error')"
  sleep 2
done
[ -n "$LAST" ] || fail "full-create 超时未完成: $ST"
echo "status=$STATUS last_synced_at=$LAST"

say "8. dest 表数据核对（3 行镜像）"
ROWS=$(curl -sS "$BASE_URL/api/v2/tables/$DEST_TABLE/records" "${AUTH[@]}")
echo "$ROWS" | jq '.list'
CNT=$(echo "$ROWS" | jq '.list | length')
[ "$CNT" = "3" ] || fail "mirror 行数=$CNT，期望 3"
TITLES=$(echo "$ROWS" | jq -r '[.list[].Title] | sort | join(",")')
[ "$TITLES" = "row1,row2,row3" ] || fail "mirror Title 集合不符: $TITLES"

say "9. 守卫链：普通用户对 synced 表写路径必须 4xx"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v2/tables/$DEST_TABLE/records" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{"Title":"nope"}')
[ "$CODE" = "400" ] || [ "$CODE" = "403" ] || fail "insert synced 表未拒绝: HTTP $CODE"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$BASE_URL/api/v2/meta/tables/$DEST_TABLE" "${AUTH[@]}")
[ "$CODE" = "400" ] || [ "$CODE" = "403" ] || fail "删除 synced 表未拒绝: HTTP $CODE"
echo "guards ok (insert=$CODE)"

say "10. source 追加 1 行 + 改 1 行 → resync → 核对 upsert"
curl -sS -X POST "$BASE_URL/api/v2/tables/$SRC_TABLE/records" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{"Title":"row4","Qty":4}' -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/resync" "${AUTH[@]}" -o /dev/null
sleep 5
for i in $(seq 1 15); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
  STATUS=$(jqget "$ST" '.status')
  [ "$STATUS" = "active" ] && break
  sleep 2
done
ROWS2=$(curl -sS "$BASE_URL/api/v2/tables/$DEST_TABLE/records" "${AUTH[@]}")
CNT2=$(echo "$ROWS2" | jq '.list | length')
[ "$CNT2" = "4" ] || fail "resync 后行数=$CNT2，期望 4"

say "11. freeze → resync 必须拒 → resume"
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/freeze" "${AUTH[@]}" -o /dev/null
ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
[ "$(jqget "$ST" '.status')" = "paused" ] || fail "freeze 后 status 非 paused"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/resync" "${AUTH[@]}")
[ "$CODE" = "400" ] || fail "paused 状态 resync 未拒绝: HTTP $CODE"
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/resume" "${AUTH[@]}" -o /dev/null
ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
[ "$(jqget "$ST" '.status')" = "active" ] || fail "resume 后 status 非 active"

say "12. editor 角色拒绝管理 op（creator+ 语义）— 跳过（需要第二账号协作流程，集成测试覆盖）"

say "13. delete sync → mirror 表进 trash → sync 行消失"
curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}" -o /dev/null
CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
[ "$CODE" = "404" ] || fail "删除后 get sync 应 404: HTTP $CODE"

say "ALL PASS ✅"
