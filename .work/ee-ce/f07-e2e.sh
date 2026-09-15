#!/bin/zsh
# f07-e2e.sh — F07 Base Snapshots API 集成自测（连 nocodb-dev）
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f01e2e@ce-ee.local"
PASS="F01e2e!pass1"
RUN_TS=$(date +%s)

say()  { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
command -v jq >/dev/null || fail "需要 jq"

CREATED_BASES=()
cleanup() {
  for b in ${CREATED_BASES[@]}; do
    curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$b" -H "xc-auth: ${TOKEN:-}" -o /dev/null 2>/dev/null || true
  done
}
trap cleanup EXIT

say "1. 登录"
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "no token"
AUTH=(-H "xc-auth: $TOKEN" -H 'Content-Type: application/json')

say "2. 建源 base + 表 + 2 行数据"
BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -d "{\"title\":\"f07_src_$RUN_TS\"}")
BID=$(echo "$BASE" | jq -r '.id // empty')
[ -n "$BID" ] || fail "create base: $BASE"
CREATED_BASES+=("$BID")
T=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/tables" "${AUTH[@]}" -d "{\"table_name\":\"t1\",\"columns\":[{\"title\":\"Name\",\"uidt\":\"SingleLineText\",\"column_name\":\"name\"}]}" | jq -r '.id // empty')
[ -n "$T" ] || fail "create table"
curl -sS -o /dev/null -X POST "$BASE_URL/api/v2/tables/$T/records" "${AUTH[@]}" -d '{"Name":"row-1"}'
curl -sS -o /dev/null -X POST "$BASE_URL/api/v2/tables/$T/records" "${AUTH[@]}" -d '{"Name":"row-2"}'

say "3. 创建快照（异步 job，轮询至 completed，≤120s）"
SNAP=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/snapshots" "${AUTH[@]}" -d '{}')
CODE=$(echo "$SNAP" | tail -1)
[ "$CODE" = "200" ] || fail "create snapshot: $(echo "$SNAP" | head -1)"
SNAP_ROW=$(echo "$SNAP" | head -1)
SID=$(echo "$SNAP_ROW" | jq -r '.id')
SNAP_BID=$(echo "$SNAP_ROW" | jq -r '.snapshot_base_id')
echo "snapshot=$SID snapshot_base=$SNAP_BID"
CREATED_BASES+=("$SNAP_BID")

STATUS="processing"
for i in $(seq 1 40); do
  STATUS=$(curl -sS "$BASE_URL/api/v2/meta/bases/$BID/snapshots/$SID" "${AUTH[@]}" | jq -r '.status')
  [ "$STATUS" = "completed" ] && break
  sleep 3
done
echo "final status: $STATUS"
[ "$STATUS" = "completed" ] || fail "snapshot never completed (status=$STATUS)"

say "4. 快照副本含数据"
SNAP_T=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SNAP_BID/tables" "${AUTH[@]}" | jq -r '.list[0].id // empty')
[ -n "$SNAP_T" ] || fail "snapshot base has no tables"
ROWS=$(curl -sS "$BASE_URL/api/v2/tables/$SNAP_T/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows')
echo "snapshot rows: $ROWS"
[ "$ROWS" = "2" ] || fail "snapshot rows != 2: $ROWS"

say "5. restore → 新 base（含数据）"
RESTORE=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/snapshots/$SID/restore" "${AUTH[@]}" -d '{}')
CODE=$(echo "$RESTORE" | tail -1)
[ "$CODE" = "200" ] || fail "restore: $(echo "$RESTORE" | head -1)"
RBID=$(echo "$RESTORE" | head -1 | jq -r '.base_id')
CREATED_BASES+=("$RBID")
echo "restored base: $RBID"
sleep 20  # restore 也是异步 job
RT=$(curl -sS "$BASE_URL/api/v2/meta/bases/$RBID/tables" "${AUTH[@]}" | jq -r '.list[0].id // empty')
RROWS=$(curl -sS "$BASE_URL/api/v2/tables/$RT/records" "${AUTH[@]}" | jq -r '.pageInfo.totalRows // 0' 2>/dev/null)
echo "restored tables: $([ -n "$RT" ] && echo ok) rows: $RROWS"

say "6. 删除快照 → 副本 base 同步消失"
curl -sS -o /dev/null -w 'delete snapshot → %{http_code}\n' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/snapshots/$SID" "${AUTH[@]}"
GONE=$(curl -sS -w '\n%{http_code}' "$BASE_URL/api/v2/meta/bases/$SNAP_BID" "${AUTH[@]}" | tail -1)
echo "$GONE" | grep -qE '^4' || fail "snapshot base should be gone: $GONE"

say "7. 清理"
CREATED_BASES=("$BID" "$RBID")
for b in $CREATED_BASES; do
  curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$b" "${AUTH[@]}" -o /dev/null -w "delete $b → %{http_code}\n"
done
CREATED_BASES=()

say "F07 E2E PASS"
