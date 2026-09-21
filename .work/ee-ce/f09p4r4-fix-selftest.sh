#!/bin/zsh
# f09p4r4-fix-selftest.sh — F09 P4-R4 修复批活体自测（:8080，nocodb-dev）
# 覆盖 lane5 E1（双 junction 共享 shadow 的 drop 腿）:
#   1 双 link 三层建成（1 shadow + 2 junction，配对回填）
#   2 删一条 link → 另一条三层完好 + 共享 shadow 保留
#   3 加回 → 仍共享 shadow（1S+2J）
#   4 一条 PATCH 删全部 link（lane5 E1 精确触发）→ 200 收敛（旧代码 404 + 部分拆毁 + 孤儿 junction）
#   5 重复轮（null 重建 → 再全删）→ 收敛可重复，零残留
set -uo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
EMAIL="${F09_E2E_EMAIL:-f01e2e@ce-ee.local}"
PASS="${F09_E2E_PASS:-F01e2e!pass1}"
RUN_TS=$(date +%s)
say()  { printf '\n== %s ==\n' "$1"; }
ok()   { printf '  PASS: %s\n' "$1"; }
bad()  { printf '  FAIL: %s\n' "$1"; FAILS=$((FAILS+1)); }
FAILS=0
command -v jq >/dev/null || { echo "需要 jq"; exit 1; }

SRC_BASE=""; DEST_BASE=""
cleanup() {
  if [ -n "${TOKEN:-}" ]; then
    [ -n "$DEST_BASE" ] && curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null
    [ -n "$SRC_BASE" ]  && curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_BASE"  -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null
  fi
}
trap cleanup EXIT

say "1. 登录"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "FAIL: 登录"; exit 1; }
AUTH=(-H "xc-auth: $TOKEN"); CT='Content-Type: application/json'
echo "token ok"

wait_active() {
  local sid=$1 i ST
  for i in {1..40}; do
    ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$sid" "${AUTH[@]}" 2>/dev/null | jq -r '.status' 2>/dev/null)
    [ "$ST" = "active" ] && return 0
    sleep 1
  done
  return 1
}
tbl_code() { curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/api/v2/meta/tables/$1" "${AUTH[@]}"; }

say "2. 源侧: T1/T2 + 行 + 双 mm link (Ns, Ns2 → 同 RT T2) + 配对 + allow_sync"
SRC_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H "$CT" -d "{\"title\":\"f09p4r4fx_src_$RUN_TS\"}" | jq -r '.id')
T1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H "$CT" \
  -d '{"table_name":"fx_t1","columns":[{"title":"Title","uidt":"SingleLineText","column_name":"title"},{"title":"Qty","uidt":"Number","column_name":"qty"}]}' | jq -r '.id')
T2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H "$CT" \
  -d '{"table_name":"fx_t2","columns":[{"title":"Name","uidt":"SingleLineText","column_name":"name"}]}' | jq -r '.id')
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" -H "$CT" -d '[{"Title":"p1","Qty":1},{"Title":"p2","Qty":2}]' -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}" -H "$CT" -d '[{"Name":"n1"},{"Name":"n2"}]' -o /dev/null
T1P1=$(curl -sS "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" | jq -r '.list[]|select(.Title=="p1")|.Id')
T1P2=$(curl -sS "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" | jq -r '.list[]|select(.Title=="p2")|.Id')
T2N1=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}" | jq -r '.list[]|select(.Name=="n1")|.Id')
T2N2=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}" | jq -r '.list[]|select(.Name=="n2")|.Id')
LC1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/tables/$T1/columns" "${AUTH[@]}" -H "$CT" \
  -d "{\"uidt\":\"Links\",\"title\":\"Ns\",\"parentId\":\"$T1\",\"childId\":\"$T2\",\"type\":\"mm\"}" | jq -r '.columns[]|select(.title=="Ns")|.id')
LC2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/tables/$T1/columns" "${AUTH[@]}" -H "$CT" \
  -d "{\"uidt\":\"Links\",\"title\":\"Ns2\",\"parentId\":\"$T1\",\"childId\":\"$T2\",\"type\":\"mm\"}" | jq -r '.columns[]|select(.title=="Ns2")|.id')
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/links/$LC1/records/$T1P1" "${AUTH[@]}" -H "$CT" -d "[{\"Id\":$T2N1}]" -o /dev/null
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/links/$LC2/records/$T1P2" "${AUTH[@]}" -H "$CT" -d "[{\"Id\":$T2N2}]" -o /dev/null
GV1=$(curl -sS "$BASE_URL/api/v2/meta/tables/$T1/views" "${AUTH[@]}" | jq -r '.list[0].id')
curl -sS -X PATCH "$BASE_URL/api/v2/meta/views/$GV1" "${AUTH[@]}" -H "$CT" -d '{"allow_sync":true}' -o /dev/null
echo "T1=$T1 T2=$T2 Ns=$LC1 Ns2=$LC2 p1=$T1P1→n1=$T2N1 p2=$T1P2→n2=$T2N2"

DEST_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H "$CT" -d "{\"title\":\"f09p4r4fx_dst_$RUN_TS\"}" | jq -r '.id')

say "3. 建 sync（双 link 同选）→ 1 shadow + 2 junction，配对回填"
S1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" -H "$CT" \
  -d "{\"title\":\"fx_s1\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T1\",\"selectedFields\":[\"Title\",\"Ns\",\"Ns2\"],\"syncTrigger\":\"manual\"}")
SYNC1=$(echo "$S1" | jq -r '.id // empty')
[ -n "$SYNC1" ] || bad "createSync: $(echo "$S1" | head -c 200)"
wait_active "$SYNC1" || bad "full-create 未收敛"
G1=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
NSH=$(echo "$G1" | jq '[.mappings[]|select(.role=="linked_shadow")]|length')
NJN=$(echo "$G1" | jq '[.mappings[]|select(.role=="junction")]|length')
MIRROR=$(echo "$G1" | jq -r '.mappings[]|select(.role=="main")|.dest_table_id')
JA1=$(echo "$G1" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | head -1)
JB1=$(echo "$G1" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | tail -1)
PA=$(curl -sS "$BASE_URL/api/v2/tables/$JA1/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
PB=$(curl -sS "$BASE_URL/api/v2/tables/$JB1/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
echo "  mirror=$MIRROR shadow=$NSH junction=$NJN ($JA1/$JB1) pairs=$PA/$PB"
[ "$NSH" = "1" ] && [ "$NJN" = "2" ] && ok "双 junction 共享一个 shadow (1S+2J)" || bad "层结构 shadow=$NSH junction=$NJN (expect 1/2)"
[ "$PA" = "1" ] && [ "$PB" = "1" ] && ok "双 junction 配对回填 1/1" || bad "pairs=$PA/$PB (expect 1/1)"

say "4. 删一条 link（保留 Ns2）→ 另一条三层完好 + 共享 shadow 保留"
HTTP=$(curl -sS -o /tmp/fx_r4_d1 -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}" -H "$CT" \
  -d '{"selectedFields":["Title","Ns2"]}')
echo "  PATCH drop Ns → HTTP $HTTP"
[ "$HTTP" = "200" ] && ok "删单条 link 200" || bad "删单条返回 $HTTP: $(cat /tmp/fx_r4_d1 | head -c 200)"
wait_active "$SYNC1" || bad "删单条后 resync 未收敛"
G2=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
NSH2=$(echo "$G2" | jq '[.mappings[]|select(.role=="linked_shadow")]|length')
NJN2=$(echo "$G2" | jq '[.mappings[]|select(.role=="junction")]|length')
SHID=$(echo "$G2" | jq -r '.mappings[]|select(.role=="linked_shadow")|.dest_table_id')
JR=$(echo "$G2" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id')
PJ=$(curl -sS "$BASE_URL/api/v2/tables/$JR/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
NSCOL=$(curl -sS "$BASE_URL/api/v2/meta/tables/$MIRROR" "${AUTH[@]}" | jq -r '[.columns[].title]|join(",")')
echo "  shadow=$NSH2 junction=$NJN2 remaining=$JR pairs=$PJ mirror_cols=$NSCOL"
[ "$NSH2" = "1" ] && ok "共享 shadow 保留（Ns2 仍引用）" || bad "shadow 数 $NSH2 (expect 1)"
[ "$NJN2" = "1" ] && ok "落选 link 的 junction mapping 已清（余 1）" || bad "junction mapping 数 $NJN2 (expect 1)"
[ "$PJ" = "1" ] && ok "保留 link 的 junction 配对完好 (1)" || bad "保留 junction pairs=$PJ (expect 1)"
[ "$(tbl_code "$SHID")" = "200" ] && ok "shadow 表在" || bad "shadow 表被误删"
echo "$NSCOL" | grep -qv '"Ns"' && echo "$NSCOL" | grep -q "Ns2" && ok "Ns 列已删 / Ns2 列保留" || bad "镜像列异常: $NSCOL"

say "5. 加回 Ns → 仍共享 shadow（1S+2J）+ 配对回填"
HTTP=$(curl -sS -o /tmp/fx_r4_add -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}" -H "$CT" \
  -d '{"selectedFields":["Title","Ns","Ns2"]}')
[ "$HTTP" = "200" ] && ok "加腿 PATCH 200" || bad "加腿返回 $HTTP: $(cat /tmp/fx_r4_add | head -c 200)"
wait_active "$SYNC1" || bad "加腿后 resync 未收敛"
G3=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
NSH3=$(echo "$G3" | jq '[.mappings[]|select(.role=="linked_shadow")]|length')
NJN3=$(echo "$G3" | jq '[.mappings[]|select(.role=="junction")]|length')
JA2=$(echo "$G3" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | head -1)
JB2=$(echo "$G3" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | tail -1)
PA2=$(curl -sS "$BASE_URL/api/v2/tables/$JA2/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
PB2=$(curl -sS "$BASE_URL/api/v2/tables/$JB2/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
echo "  shadow=$NSH3 junction=$NJN3 pairs=$PA2/$PB2"
[ "$NSH3" = "1" ] && [ "$NJN3" = "2" ] && ok "加回复用共享 shadow (1S+2J)" || bad "层结构 shadow=$NSH3 junction=$NJN3 (expect 1/2)"
[ "$PA2" = "1" ] && [ "$PB2" = "1" ] && ok "双 junction 配对回填 1/1" || bad "pairs=$PA2/$PB2 (expect 1/1)"

say "6. lane5 E1 精确触发: 一条 PATCH 删全部 link → 200 收敛 + 零残留（旧代码此处 404 + 孤儿 junction）"
HTTP=$(curl -sS -o /tmp/fx_r4_dropall -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}" -H "$CT" \
  -d '{"selectedFields":["Title"]}')
echo "  PATCH drop all links → HTTP $HTTP"
[ "$HTTP" = "200" ] && ok "全删 PATCH 200（旧代码 404 ERR_FIELD_NOT_FOUND）" || bad "全删返回 $HTTP: $(cat /tmp/fx_r4_dropall | head -c 300)"
wait_active "$SYNC1" || bad "全删后 resync 未收敛"
G4=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
ROLES=$(echo "$G4" | jq -r '[.mappings[].role]|join(",")')
NM4=$(echo "$G4" | jq '.mappings | length')
echo "  roles=$ROLES (mappings=$NM4)"
[ "$ROLES" = "main" ] && ok "junction/shadow mapping 全清（roles=[main]，旧代码残留孤儿 junction）" || bad "roles=$ROLES (expect main)"
for jt in "$JA2" "$JB2"; do
  [ "$(tbl_code "$jt")" = "404" ] && ok "junction 表 $jt 已删" || bad "junction 表 $jt 仍存在 ($(tbl_code "$jt"))"
done
[ "$(tbl_code "$SHID")" = "404" ] && ok "shadow 表已删" || bad "shadow 表仍存在"
MCOLS4=$(curl -sS "$BASE_URL/api/v2/meta/tables/$MIRROR" "${AUTH[@]}" | jq -r '[.columns[].title]|join(",")')
echo "$MCOLS4" | grep -q "Ns" && bad "镜像 link 列残留: $MCOLS4" || ok "镜像 link 列全删 ($MCOLS4)"

say "7. 重复轮收敛: null 重建 → 再全删 → 仍零残留"
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}" -H "$CT" -d '{"selectedFields":null}')
[ "$HTTP" = "200" ] && ok "null 重建 PATCH 200" || bad "null 返回 $HTTP"
wait_active "$SYNC1" || bad "重建 resync 未收敛"
G5=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
NSH5=$(echo "$G5" | jq '[.mappings[]|select(.role=="linked_shadow")]|length')
NJN5=$(echo "$G5" | jq '[.mappings[]|select(.role=="junction")]|length')
JA3=$(echo "$G5" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | head -1)
JB3=$(echo "$G5" | jq -r '.mappings[]|select(.role=="junction")|.dest_table_id' | tail -1)
PA3=$(curl -sS "$BASE_URL/api/v2/tables/$JA3/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
PB3=$(curl -sS "$BASE_URL/api/v2/tables/$JB3/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
echo "  重建后 shadow=$NSH5 junction=$NJN5 pairs=$PA3/$PB3"
[ "$NSH5" = "1" ] && [ "$NJN5" = "2" ] && [ "$PA3" = "1" ] && [ "$PB3" = "1" ] && ok "第二轮三层重建完好 (1S+2J, 1/1)" || bad "重建异常 shadow=$NSH5 junction=$NJN5 pairs=$PA3/$PB3"
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}" -H "$CT" \
  -d '{"selectedFields":["Title"]}')
[ "$HTTP" = "200" ] && ok "第二轮全删 PATCH 200" || bad "第二轮全删返回 $HTTP"
wait_active "$SYNC1" || bad "第二轮全删后未收敛"
G6=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$SYNC1" "${AUTH[@]}")
ROLES6=$(echo "$G6" | jq -r '[.mappings[].role]|join(",")')
[ "$ROLES6" = "main" ] && ok "第二轮全清（roles=[main]）" || bad "第二轮 roles=$ROLES6"
for jt in "$JA3" "$JB3"; do
  [ "$(tbl_code "$jt")" = "404" ] && ok "第二轮 junction 表 $jt 已删" || bad "第二轮 junction 表 $jt 残留"
done

say "收尾"
echo "FAILS=$FAILS"
[ "$FAILS" = "0" ] && echo "ALL PASS" || echo "HAS FAILURES"
exit "$FAILS"
