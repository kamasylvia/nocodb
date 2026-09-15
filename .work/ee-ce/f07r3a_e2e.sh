#!/bin/zsh
# f07r3a_e2e.sh — F07 Snapshots R3 集成抽验（int 路）
# 生命周期: create→completed→副本数据→restore→delete + 删源 base 行清零(DB 步另跑)
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f07r3a.1789220787@ce-ee.local"
PASS="F07r3a!pass1"
RUN_TS=$(date +%s)
WORK=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce

say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
command -v jq >/dev/null || fail "需要 jq"

SRC_BASE=""
RESTORED_BASE=""

say "1. 登录"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
fi
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "no token"
AUTH=(-H "xc-auth: $TOKEN" -H 'Content-Type: application/json')
echo "token ok"

say "2. 建 base + table + 3 行数据"
BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f07r3a_src_$RUN_TS\"}")
SRC_BASE=$(echo "$BASE" | jq -r '.id // empty')
[ -n "$SRC_BASE" ] || fail "create base: $BASE"
echo "src base: $SRC_BASE"

TBL=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -d '{
  "table_name": "inventory",
  "columns": [
    {"title":"Name","uidt":"SingleLineText","column_name":"name"},
    {"title":"Qty","uidt":"Number","column_name":"qty"}
  ]
}')
TBL_ID=$(echo "$TBL" | jq -r '.id // empty')
[ -n "$TBL_ID" ] || fail "create table: $TBL"

INS=$(curl -sS -X POST "$BASE_URL/api/v2/tables/$TBL_ID/records" "${AUTH[@]}" -d '[
  {"Name":"alpha","Qty":1},{"Name":"beta","Qty":2},{"Name":"gamma","Qty":3}
]')
INS_N=$(echo "$INS" | jq 'length // 0' 2>/dev/null || echo 0)
[ "$INS_N" = "3" ] || fail "insert records: $INS"
echo "3 records inserted (table $TBL_ID)"

say "3. create snapshot"
SNAP=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots" "${AUTH[@]}" -d '{"title":"f07r3a snap A"}')
CODE=$(echo "$SNAP" | tail -1); BODY=$(echo "$SNAP" | head -1)
[ "$CODE" = "200" ] || fail "create snapshot: $CODE $BODY"
SNAP_ID=$(echo "$BODY" | jq -r '.id')
SNAP_STATUS0=$(echo "$BODY" | jq -r '.status')
SNAP_BASE_ID=$(echo "$BODY" | jq -r '.snapshot_base_id')
echo "snapshot: id=$SNAP_ID status=$SNAP_STATUS0 copy_base=$SNAP_BASE_ID"
echo "$SNAP_ID" > "$WORK/f07r3a_snapid"
echo "$SRC_BASE" > "$WORK/f07r3a_srcbase"

say "3b. mutex: processing 中再 create → 期望 400"
MUTEX=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots" "${AUTH[@]}" -d '{}')
MCODE=$(echo "$MUTEX" | tail -1)
echo "mutex code=$MCODE"
[ "$MCODE" = "400" ] || echo "NOTE: mutex not triggered (copy may already be done) code=$MCODE"

say "3c. title 校验: 非字符串 → 400; >512 → 400"
T1=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots" "${AUTH[@]}" -d '{"title":12345}')
T2=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots" "${AUTH[@]}" -d "{\"title\":\"$(printf 'x%.0s' $(seq 1 600))\"}")
echo "non-string=$T1 over512=$T2"
[ "$T1" = "400" ] && [ "$T2" = "400" ] || fail "title validation: $T1/$T2"

say "4. 轮询 snapshot → completed"
FINAL=""
for i in $(seq 1 40); do
  S=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP_ID" "${AUTH[@]}")
  ST=$(echo "$S" | jq -r '.status')
  echo "  poll $i: $ST"
  if [ "$ST" = "completed" ] || [ "$ST" = "error" ]; then FINAL=$ST; break; fi
  sleep 3
done
[ "$FINAL" = "completed" ] || fail "snapshot never completed: $FINAL"
echo "completed OK"

say "4b. 副本 base 数据验证"
SNAP_TBL=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SNAP_BASE_ID/tables" "${AUTH[@]}" | jq -r '.list[] | select(.title=="inventory") | .id' | head -1)
[ -n "$SNAP_TBL" ] || fail "copy base table 'inventory' not found"
COPY_N=$(curl -sS "$BASE_URL/api/v2/tables/$SNAP_TBL/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows // .list | length' 2>/dev/null | head -1)
echo "copy table=$SNAP_TBL rows=$COPY_N"
[ "$COPY_N" = "3" ] || fail "copy rows != 3: $COPY_N"

say "5. restore → 200 + 新 base + 数据在"
RES=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP_ID/restore" "${AUTH[@]}" -d '{}')
RCODE=$(echo "$RES" | tail -1); RBODY=$(echo "$RES" | head -1)
[ "$RCODE" = "200" ] || fail "restore: $RCODE $RBODY"
RESTORED_BASE=$(echo "$RBODY" | jq -r '.base_id')
[ -n "$RESTORED_BASE" ] || fail "no restored base_id: $RBODY"
echo "restored base: $RESTORED_BASE"
# restore 同样是异步 job — 轮询 restored base 直到 inventory 表出现
RES_TBL=""
for i in $(seq 1 40); do
  RES_TBL=$(curl -sS "$BASE_URL/api/v2/meta/bases/$RESTORED_BASE/tables" "${AUTH[@]}" | jq -r '.list[] | select(.title=="inventory") | .id' | head -1)
  [ -n "$RES_TBL" ] && break
  sleep 3
done
[ -n "$RES_TBL" ] || fail "restored base table 'inventory' never appeared"
RES_N=$(curl -sS "$BASE_URL/api/v2/tables/$RES_TBL/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows // .list | length' 2>/dev/null | head -1)
echo "restored table=$RES_TBL rows=$RES_N"
[ "$RES_N" = "3" ] || fail "restored rows != 3: $RES_N"

say "6. 攻击: 直接删快照副本 base → GET snapshot 应派生 error → restore 应 400"
DEL2=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SNAP_BASE_ID" "${AUTH[@]}")
echo "delete copy base: $DEL2"
sleep 1
G=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP_ID" "${AUTH[@]}")
GS=$(echo "$G" | jq -r '.status')
echo "derived status after copy deleted: $GS"
[ "$GS" = "error" ] || fail "deriveStatus expected error, got $GS"
RA=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP_ID/restore" "${AUTH[@]}" -d '{}')
echo "restore on error snapshot: $RA"
[ "$RA" = "400" ] || fail "restore should 400 on error snapshot: $RA"

say "7. 404 边界: 跨 base / 不存在 id"
NF1=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$RESTORED_BASE/snapshots/$SNAP_ID" "${AUTH[@]}")
NF2=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/nonexist99" "${AUTH[@]}")
echo "cross-base=$NF1 nonexistent=$NF2"
[ "$NF1" = "404" ] && [ "$NF2" = "404" ] || fail "404 edges: $NF1/$NF2"

say "8. 建 B 快照再 delete 快照（副本应 softDelete, 行消失）"
SNAP2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots" "${AUTH[@]}" -d '{"title":"f07r3a snap B"}')
SNAP2_ID=$(echo "$SNAP2" | jq -r '.id'); SNAP2_BASE=$(echo "$SNAP2" | jq -r '.snapshot_base_id')
echo "snapB: id=$SNAP2_ID copy=$SNAP2_BASE"
for i in $(seq 1 40); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP2_ID" "${AUTH[@]}" | jq -r '.status')
  [ "$ST" = "completed" ] && break
  [ "$ST" = "error" ] && fail "snapB error"
  sleep 3
done
[ "$ST" = "completed" ] || fail "snapB never completed: $ST"
echo "$SNAP2_BASE" > "$WORK/f07r3a_snapb_base"
DS=$(curl -sS -w '\n%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP2_ID" "${AUTH[@]}")
DSC=$(echo "$DS" | tail -1)
[ "$DSC" = "200" ] || fail "delete snapshot: $DSC"
DSG=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$SRC_BASE/snapshots/$SNAP2_ID" "${AUTH[@]}")
echo "get after delete: $DSG"
[ "$DSG" = "404" ] || fail "snapshot still reachable after delete: $DSG"

say "9. 删源 base（hook 应清 nc_snapshots）"
DB=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_BASE" "${AUTH[@]}")
echo "delete src base: $DB"
[ "$DB" = "200" ] || fail "delete src base: $DB"

say "10. 清理 restored base"
if [ -n "$RESTORED_BASE" ]; then
  RB=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$RESTORED_BASE" "${AUTH[@]}")
  echo "delete restored base: $RB"
fi

say "DONE — DB 清零验证由 f07r3a_dbq.py 另跑"
