#!/bin/zsh
# f09-p4-selftest.sh — F09 P4 LTAR 三层（Main link 列 + LinkedShadow + Junction）API 全流程自测
# 前置: 后端 :8080 含 P4 构建；jq 可用。凭证零落盘（用已存在的测试账号）。
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
EMAIL="${F09_E2E_EMAIL:-f01e2e@ce-ee.local}"
PASS="${F09_E2E_PASS:-F01e2e!pass1}"
RUN_TS=$(date +%s)
say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
jqget() { echo "$1" | jq -r "$2"; }

command -v jq >/dev/null || fail "需要 jq"

SRC_BASE=""; DEST_BASE=""
cleanup() {
  if [ -n "${DEST_BASE:-}" ] && [ -n "${TOKEN:-}" ]; then
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null || true
  fi
}
trap cleanup EXIT

say "1. 登录"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "拿不到 token"
AUTH=(-H "xc-auth: $TOKEN")
echo "token ok"

say "2. 源侧：T1/T2 两表 + 行 + mm link 列 + 配对 + allow_sync"
SRC_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p4_src_$RUN_TS\"}" | jq -r '.id')
[ -n "$SRC_BASE" ] || fail "建 source base 失败"
T1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"table_name":"f09p4_t1","columns":[{"title":"Title","uidt":"SingleLineText","column_name":"title"},{"title":"Qty","uidt":"Number","column_name":"qty"}]}' | jq -r '.id')
T2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"table_name":"f09p4_t2","columns":[{"title":"Name","uidt":"SingleLineText","column_name":"name"}]}' | jq -r '.id')
[ -n "$T1" ] && [ -n "$T2" ] || fail "建源表失败"

for i in 1 2 3; do
  curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"Title\":\"p$i\",\"Qty\":$i}" -o /dev/null
  curl -sS -X POST "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"Name\":\"n$i\"}" -o /dev/null
done
T1_ROWS=$(curl -sS "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}")
T2_ROWS=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}")
T1_R1=$(jqget "$T1_ROWS" '.list[] | select(.Title=="p1") | .Id')
T1_R2=$(jqget "$T1_ROWS" '.list[] | select(.Title=="p2") | .Id')
T1_R3=$(jqget "$T1_ROWS" '.list[] | select(.Title=="p3") | .Id')
T2_R1=$(jqget "$T2_ROWS" '.list[] | select(.Name=="n1") | .Id')
T2_R2=$(jqget "$T2_ROWS" '.list[] | select(.Name=="n2") | .Id')
T2_R3=$(jqget "$T2_ROWS" '.list[] | select(.Name=="n3") | .Id')

# mm link 列挂在 T1 上（parentId=自身 T1, childId=关联 T2）
# POST /columns 返回刷新后的 Model（P2 已知行为）——列 id 从 .columns 按 title 捞
LINK_RESP=$(curl -sS -X POST "$BASE_URL/api/v2/meta/tables/$T1/columns" "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"uidt\":\"Links\",\"title\":\"T2s\",\"column_name\":\"t2s\",\"parentId\":\"$T1\",\"childId\":\"$T2\",\"type\":\"mm\"}")
LINK_COL_ID=$(jqget "$LINK_RESP" '.columns[] | select(.title=="T2s") | .id')
[ -n "$LINK_COL_ID" ] && [ "$LINK_COL_ID" != "null" ] || fail "建 link 列失败: $(echo "$LINK_RESP" | head -c 300)"

# 配对 p1→n1, p2→n2
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/links/$LINK_COL_ID/records/$T1_R1" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "[$T2_R1]" -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/links/$LINK_COL_ID/records/$T1_R2" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "[$T2_R2]" -o /dev/null
echo "source ready: base=$SRC_BASE T1=$T1 T2=$T2 link_col=$LINK_COL_ID pairs=2"

VIEWS=$(curl -sS "$BASE_URL/api/v2/meta/tables/$T1/views" "${AUTH[@]}")
GRID_VIEW=$(echo "$VIEWS" | jq -r '.list[] | select(.type==3) | .id' | head -1)
curl -sS -X PATCH "$BASE_URL/api/v2/meta/views/$GRID_VIEW" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"allow_sync":true}' -o /dev/null

say "3. dest base + 创建 sync（selectedFields=null 全字段含 link）"
DEST_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p4_dest_$RUN_TS\"}" | jq -r '.id')
[ -n "$DEST_BASE" ] || fail "建 dest base 失败"

SCHEMA=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/source-schema" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "{\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T1\"}")
echo "$SCHEMA" | jq -c '.columns'
[ "$(echo "$SCHEMA" | jq '[.columns[] | select(.link==true)] | length')" = "1" ] || fail "schema 未暴露 link 列"

SYNC=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p4_sync_$RUN_TS\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T1\",\"sourceViewId\":\"$GRID_VIEW\",\"onDeleteAction\":\"delete\",\"syncTrigger\":\"manual\"}")
SYNC_ID=$(jqget "$SYNC" '.id')
[ -n "$SYNC_ID" ] && [ "$SYNC_ID" != "null" ] || fail "创建 sync 失败: $SYNC"
echo "$SYNC" | jq -c '.mappings[] | {role, source_table_id, dest_table_id}'

say "4. 断言三层 mapping 角色"
[ "$(jqget "$SYNC" '[.mappings[] | select(.role=="main")] | length')" = "1" ] || fail "main mapping != 1"
[ "$(jqget "$SYNC" '[.mappings[] | select(.role=="linked_shadow")] | length')" = "1" ] || fail "linked_shadow mapping != 1"
[ "$(jqget "$SYNC" '[.mappings[] | select(.role=="junction")] | length')" = "1" ] || fail "junction mapping != 1"
MIRROR_T=$(jqget "$SYNC" '.mappings[] | select(.role=="main") | .dest_table_id')
SHADOW_T=$(jqget "$SYNC" '.mappings[] | select(.role=="linked_shadow") | .dest_table_id')
JUNC_T=$(jqget "$SYNC" '.mappings[] | select(.role=="junction") | .dest_table_id')
echo "mirror=$MIRROR_T shadow=$SHADOW_T junction=$JUNC_T"

say "5. 等 full-create 完成"
LAST=""; STATUS=""
for i in $(seq 1 30); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
  STATUS=$(jqget "$ST" '.status'); LAST=$(jqget "$ST" '.last_synced_at // empty')
  [ "$STATUS" = "active" ] && [ -n "$LAST" ] && break
  [ "$STATUS" = "error" ] && fail "sync error: $(jqget "$ST" '.last_error')"
  sleep 2
done
[ -n "$LAST" ] || fail "full-create 超时"
echo "status=$STATUS"

say "6. 断言 synced 语义（mirror/shadow/junction 全 synced=true）"
for t in $MIRROR_T $SHADOW_T $JUNC_T; do
  FLAG=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/tables?includeM2M=true" "${AUTH[@]}" | jq -r ".list[] | select(.id==\"$t\") | .synced")
  [ "$FLAG" = "true" ] || fail "表 $t synced != true (=$FLAG)"
done
echo "synced flags ok"

say "7. 断言数据：mirror 3 行 / shadow 3 行 / junction 2 配对"
CNT=$(curl -sS "$BASE_URL/api/v2/tables/$MIRROR_T/records" "${AUTH[@]}" | jq '.list | length')
[ "$CNT" = "3" ] || fail "mirror 行数=$CNT"
SCNT=$(curl -sS "$BASE_URL/api/v2/tables/$SHADOW_T/records" "${AUTH[@]}" | jq '.list | length')
[ "$SCNT" = "3" ] || fail "shadow 行数=$SCNT"
JROWS=$(curl -sS "$BASE_URL/api/v2/tables/$JUNC_T/records" "${AUTH[@]}")
echo "$JROWS" | jq -c '.list'
JCNT=$(echo "$JROWS" | jq '.list | length')
[ "$JCNT" = "2" ] || fail "junction 配对数=$JCNT，期望 2"

say "8. 源侧加配对 p3→n3 + resync → junction=3, shadow 不变"
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/links/$LINK_COL_ID/records/$T1_R3" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "[$T2_R3]" -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/resync" "${AUTH[@]}" -o /dev/null
for i in $(seq 1 20); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && break
  sleep 2
done
JCNT2=$(curl -sS "$BASE_URL/api/v2/tables/$JUNC_T/records" "${AUTH[@]}" | jq '.list | length')
[ "$JCNT2" = "3" ] || fail "resync 后 junction 配对数=$JCNT2，期望 3"
echo "junction pairs after relink = $JCNT2"

say "9. 源侧删配对 p1→n1 + resync → junction=2"
curl -sS -X DELETE "$BASE_URL/api/v2/tables/$T1/links/$LINK_COL_ID/records/$T1_R1" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d "[$T2_R1]" -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID/resync" "${AUTH[@]}" -o /dev/null
for i in $(seq 1 20); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && break
  sleep 2
done
JCNT3=$(curl -sS "$BASE_URL/api/v2/tables/$JUNC_T/records" "${AUTH[@]}" | jq '.list | length')
[ "$JCNT3" = "2" ] || fail "unlink 后 junction 配对数=$JCNT3，期望 2"
echo "junction pairs after unlink = $JCNT3"

say "10. 守卫链：junction 表直写必须 4xx"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v2/tables/$JUNC_T/records" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{}')
# 422 = ERR_SYNC_TABLE_OPERATION_PROHIBITED（与 P2 editor 删镜像行 422 同源语义）
[ "$CODE" = "400" ] || [ "$CODE" = "403" ] || [ "$CODE" = "422" ] || fail "junction 直写未拒绝: HTTP $CODE"
echo "junction guard ok ($CODE)"

say "11. updateSync 去 link 字段 → junction + shadow 级联 drop"
PATCH=$(curl -sS -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC_ID" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{"selected_fields":["Title","Qty"]}')
echo "$PATCH" | jq -c '.mappings[] | {role}'
[ "$(jqget "$PATCH" '[.mappings[] | select(.role=="junction" or .role=="linked_shadow")] | length')" = "0" ] || fail "级联后仍有 junction/shadow mapping"
JUNC_GONE=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/tables?includeM2M=true" "${AUTH[@]}" | jq -r "[.list[] | select(.id==\"$JUNC_T\" or .id==\"$SHADOW_T\")] | length")
[ "$JUNC_GONE" = "0" ] || fail "junction/shadow 表仍在 base 列表（=$JUNC_GONE）"
MIRROR_LNK=$(curl -sS "$BASE_URL/api/v2/meta/tables/$MIRROR_T" "${AUTH[@]}" | jq '[.columns[] | select(.title=="T2s")] | length')
[ "$MIRROR_LNK" = "0" ] || fail "mirror 上 link 列未删除"
echo "cascade drop ok"

say "12. deleteSync 级联清理（新 sync：含 link → 删除 sync → 三表全走）"
SYNC2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p4_sync2_$RUN_TS\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T1\",\"sourceViewId\":\"$GRID_VIEW\",\"onDeleteAction\":\"delete\",\"syncTrigger\":\"manual\"}")
SYNC2_ID=$(jqget "$SYNC2" '.id')
for i in $(seq 1 30); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC2_ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && [ -n "$(jqget "$ST" '.last_synced_at // empty')" ] && break
  sleep 2
done
M2=$(jqget "$SYNC2" '.mappings[] | select(.role=="main") | .dest_table_id')
S2=$(jqget "$SYNC2" '.mappings[] | select(.role=="linked_shadow") | .dest_table_id')
J2=$(jqget "$SYNC2" '.mappings[] | select(.role=="junction") | .dest_table_id')
curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC2_ID" "${AUTH[@]}" -o /dev/null
LEFT=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/tables?includeM2M=true" "${AUTH[@]}" | jq -r "[.list[] | select(.id==\"$M2\" or .id==\"$S2\" or .id==\"$J2\")] | length")
[ "$LEFT" = "0" ] || fail "deleteSync 后仍有 $LEFT 张表残留"
echo "deleteSync cascade ok"

say "ALL PASS"
