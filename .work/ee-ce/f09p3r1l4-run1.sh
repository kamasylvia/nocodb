#!/bin/zsh
# f09p3r1l4-run1.sh — F09 P3 R1 lane4 引擎活体审查
# 覆盖: realtime 全链(insert/update/delete 增量跟随) / 防环守卫 / 事件风暴
#       / Syncing CAS 跳过 + 补齐水位 / mark_deleted 策略 / realtime resync 可用
# 只读审查约束: 不改源码, 不动 :8080 服务; 测试数据 f09p3r1l4- 前缀, 测完删
set -uo pipefail
BASE_URL="http://127.0.0.1:8080"
EMAIL="f09p3r1l4-api@ce-ee.local"
PASSW="F09p3r1l4!pass"
TS=$(date +%s)
RES=/tmp/f09p3r1l4-results.txt
: > "$RES"

say()  { printf '\n== %s ==\n' "$1" | tee -a "$RES"; }
ok()   { printf 'PASS: %s\n' "$1" | tee -a "$RES"; }
bad()  { printf 'FAIL: %s (%s)\n' "$1" "${2:-}" | tee -a "$RES"; }
note() { printf 'NOTE: %s\n' "$1" | tee -a "$RES"; }
jqget() { echo "$1" | jq -r "$2"; }

command -v jq >/dev/null || { echo "需要 jq"; exit 1; }

SRC_BASE=""; DEST_BASE=""
cleanup() {
  [ -n "${TOKEN:-}" ] || return 0
  for s in "${SYNC1:-}" "${SYNC2:-}"; do
    [ -n "$s" ] && curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$s" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null
  done
  for b in "${DEST_BASE:-}" "${SRC_BASE:-}"; do
    [ -n "$b" ] && curl -sS -X DELETE "$BASE_URL/api/v2/meta/bases/$b" -H "xc-auth: $TOKEN" -o /dev/null 2>/dev/null
  done
  echo "cleanup done" | tee -a "$RES"
}
trap cleanup EXIT

say "1. 登录（infra 建 base + 邀请 lane 账号 owner，沿用前轮模式）"
INFRA_EMAIL="f01e2e@ce-ee.local"; INFRA_PASS="F01e2e!pass1"
ITOK=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$INFRA_EMAIL\",\"password\":\"$INFRA_PASS\"}" | jq -r '.token // empty')
[ -n "$ITOK" ] || { echo "no infra token"; exit 1; }
TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSW\"}" | jq -r '.token // empty')
[ -z "$TOKEN" ] && TOKEN=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSW\"}" | jq -r '.token // empty')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "no token"; exit 1; }
AUTH=(-H "xc-auth: $TOKEN")
IAUTH=(-H "xc-auth: $ITOK")
ok "tokens"

say "2. 建 source base + 两张表 + 数据"
SRC_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${IAUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p3r1l4_src_$TS\"}" | jq -r '.id')
DEST_BASE=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${IAUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p3r1l4_dest_$TS\"}" | jq -r '.id')
[ -n "$SRC_BASE" ] && [ -n "$DEST_BASE" ] || { echo "base create fail"; exit 1; }
for B in "$SRC_BASE" "$DEST_BASE"; do
  curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$B/users" "${IAUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"roles\":\"owner\"}" -o /dev/null
done
ok "bases + owner invite"

T1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"table_name\":\"f09p3r1l4_t1_$TS\",\"columns\":[
    {\"title\":\"Title\",\"uidt\":\"SingleLineText\"},
    {\"title\":\"Qty\",\"uidt\":\"Number\"}
  ]}" | jq -r '.id')
T2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_BASE/tables" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"table_name\":\"f09p3r1l4_t2_$TS\",\"columns\":[
    {\"title\":\"Title\",\"uidt\":\"SingleLineText\"}
  ]}" | jq -r '.id')
[ -n "$T1" ] && [ -n "$T2" ] || { echo "table create fail"; exit 1; }

for i in 1 2 3; do
  curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"Title\":\"row$i\",\"Qty\":$i}" -o /dev/null
done
for n in a1 a2 a3; do
  curl -sS -X POST "$BASE_URL/api/v2/tables/$T2/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"Title\":\"$n\"}" -o /dev/null
done
# 各表默认 grid view 开 allow_sync
GV1=$(curl -sS "$BASE_URL/api/v2/meta/tables/$T1/views" "${AUTH[@]}" | jq -r '.list[] | select(.type==3) | .id' | head -1)
GV2=$(curl -sS "$BASE_URL/api/v2/meta/tables/$T2/views" "${AUTH[@]}" | jq -r '.list[] | select(.type==3) | .id' | head -1)
curl -sS -X PATCH "$BASE_URL/api/v2/meta/views/$GV1" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"allow_sync":true}' -o /dev/null
curl -sS -X PATCH "$BASE_URL/api/v2/meta/views/$GV2" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"allow_sync":true}' -o /dev/null
ok "src ready: SRC=$SRC_BASE T1=$T1 T2=$T2 DEST=$DEST_BASE"

say "3. T1 realtime createSync (delete 策略)"
SYNC1=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p3r1l4_rt_$TS\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T1\",\"sourceViewId\":\"$GV1\",\"onDeleteAction\":\"delete\",\"syncTrigger\":\"realtime\"}")
S1ID=$(jqget "$SYNC1" '.id')
TRIG=$(jqget "$SYNC1" '.syncTrigger // .sync_trigger // empty')
[ "$TRIG" = "realtime" ] && ok "createSync realtime 200, trigger=$TRIG" || bad "createSync trigger" "$SYNC1"
M1=$(jqget "$SYNC1" '.mappings[] | select(.role=="main") | .dest_table_id')
[ -n "$M1" ] || { echo "no mirror table"; exit 1; }

# 等 full-create
for i in $(seq 1 40); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && [ -n "$(jqget "$ST" '.last_synced_at // empty')" ] && break
  sleep 1.5
done
[ "$(jqget "$ST" '.status')" = "active" ] && ok "full-create done" || bad "full-create" "$ST"
CNT=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records" "${AUTH[@]}" | jq '.list | length')
[ "$CNT" = "3" ] && ok "mirror=3 rows" || bad "mirror rows" "$CNT"

say "4. realtime insert 跟随 + 延迟"
N=0; FOUND=0
curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"Title":"row4","Qty":4}' -o /dev/null
while [ $N -lt 100 ]; do
  HIT=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records?where=(Title,eq,row4)" "${AUTH[@]}" | jq '.list | length')
  if [ "$HIT" = "1" ]; then FOUND=1; break; fi
  sleep 0.3; N=$((N+1))
done
if [ $FOUND = 1 ]; then ok "insert row4 mirrored in ~$((N*300))ms (polls=$N)"; else bad "insert row4 not mirrored in 30s" ""; fi

say "5. realtime update 跟随"
RID2=$(curl -sS "$BASE_URL/api/v2/tables/$T1/records?where=(Title,eq,row2)" "${AUTH[@]}" | jq -r '.list[0].Id')
curl -sS -X PATCH "$BASE_URL/api/v2/tables/$T1/records/$RID2" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"Qty":99}' -o /dev/null
N=0; FOUND=0
while [ $N -lt 100 ]; do
  Q=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records?where=(Title,eq,row2)" "${AUTH[@]}" | jq -r '.list[0].Qty // empty')
  if [ "$Q" = "99" ]; then FOUND=1; break; fi
  sleep 0.3; N=$((N+1))
done
[ $FOUND = 1 ] && ok "update row2.Qty=99 mirrored in ~$((N*300))ms" || bad "update row2 not mirrored" ""

say "6. realtime delete 跟随 (delete 策略)"
RID3=$(curl -sS "$BASE_URL/api/v2/tables/$T1/records?where=(Title,eq,row3)" "${AUTH[@]}" | jq -r '.list[0].Id')
curl -sS -X DELETE "$BASE_URL/api/v2/tables/$T1/records/$RID3" "${AUTH[@]}" -o /dev/null
N=0; FOUND=0
while [ $N -lt 100 ]; do
  H=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records?where=(Title,eq,row3)" "${AUTH[@]}" | jq '.list | length')
  if [ "$H" = "0" ]; then FOUND=1; break; fi
  sleep 0.3; N=$((N+1))
done
[ $FOUND = 1 ] && ok "delete row3 mirrored (row gone) in ~$((N*300))ms" || bad "delete row3 not mirrored" ""

say "7. 防环: mirror 侧 allow_sync 应拒 + 无 job churn"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/tables/$M1/views" "${AUTH[@]}" -o /dev/null) # 占位
MV=$(curl -sS "$BASE_URL/api/v2/meta/tables/$M1/views" "${AUTH[@]}" | jq -r '.list[] | select(.type==3) | .id' | head -1)
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE_URL/api/v2/meta/views/$MV" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"allow_sync":true}')
case "$CODE" in 400|403) ok "mirror view allow_sync rejected: HTTP $CODE";; *) bad "mirror view allow_sync NOT rejected" "HTTP $CODE";; esac
SNAP=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID" "${AUTH[@]}" | jq -c '{s:.status,l:.lastSyncedAt,j:.syncJobId}')
sleep 8
SNAP2=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID" "${AUTH[@]}" | jq -c '{s:.status,l:.lastSyncedAt,j:.syncJobId}')
[ "$SNAP" = "$SNAP2" ] && ok "no sync churn in quiet window ($SNAP)" || bad "sync churn without source writes" "$SNAP -> $SNAP2"

say "8. 事件风暴: 15 连发 insert"
for i in $(seq 1 15); do
  curl -sS -X POST "$BASE_URL/api/v2/tables/$T1/records" "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d "{\"Title\":\"storm$i\",\"Qty\":$i}" -o /dev/null
done
N=0; FOUND=0
while [ $N -lt 150 ]; do
  CNT=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records?limit=100" "${AUTH[@]}")
  HIT=$(echo "$CNT" | jq '[.list[] | select(.Title | startswith("storm"))] | length')
  if [ "$HIT" = "15" ]; then FOUND=1; break; fi
  sleep 0.3; N=$((N+1))
done
[ $FOUND = 1 ] && ok "storm 15/15 mirrored in ~$((N*300))ms" || bad "storm incomplete" "hit=$HIT"
DUP=$(curl -sS "$BASE_URL/api/v2/tables/$M1/records?limit=100" "${AUTH[@]}" | jq '[.list[].RemoteId] | group_by(.) | map(select(length>1)) | length')
[ "$DUP" = "0" ] && ok "no duplicate RemoteId" || bad "duplicate RemoteId" "$DUP"
SST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID" "${AUTH[@]}" | jq -r '.status')
[ "$SST" = "active" ] && ok "post-storm status=active" || bad "post-storm status" "$SST"

say "9. realtime sync 手动 resync 仍可用"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID/resync" "${AUTH[@]}")
[ "$CODE" = "200" ] && ok "resync on realtime sync 200" || bad "resync on realtime sync" "HTTP $CODE"
for i in $(seq 1 30); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S1ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && break; sleep 1.5
done
[ "$(jqget "$ST" '.status')" = "active" ] && ok "post-resync active" || bad "post-resync status" "$ST"

say "10. T2 mark_deleted realtime sync"
SYNC2=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"f09p3r1l4_md_$TS\",\"sourceBaseId\":\"$SRC_BASE\",\"sourceTableId\":\"$T2\",\"sourceViewId\":\"$GV2\",\"onDeleteAction\":\"mark_deleted\",\"syncTrigger\":\"realtime\"}")
S2ID=$(jqget "$SYNC2" '.id')
M2=$(jqget "$SYNC2" '.mappings[] | select(.role=="main") | .dest_table_id')
for i in $(seq 1 40); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && break; sleep 1.5
done
[ "$(jqget "$ST" '.status')" = "active" ] && ok "sync2 full-create done (mirror=$M2)" || bad "sync2 full-create" "$ST"

say "11. freeze 窗口内事件 → 跳过验证"
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID/freeze" "${AUTH[@]}" -o /dev/null
ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID" "${AUTH[@]}")
[ "$(jqget "$ST" '.status')" = "paused" ] && ok "freeze ok" || bad "freeze" "$ST"
# 窗口内: 改 a1, 删 a2
RA1=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records?where=(Title,eq,a1)" "${AUTH[@]}" | jq -r '.list[0].Id')
RA2=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records?where=(Title,eq,a2)" "${AUTH[@]}" | jq -r '.list[0].Id')
RA3=$(curl -sS "$BASE_URL/api/v2/tables/$T2/records?where=(Title,eq,a3)" "${AUTH[@]}" | jq -r '.list[0].Id')
curl -sS -X PATCH "$BASE_URL/api/v2/tables/$T2/records/$RA1" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Title":"a1-edited"}' -o /dev/null
curl -sS -X DELETE "$BASE_URL/api/v2/tables/$T2/records/$RA2" "${AUTH[@]}" -o /dev/null
sleep 2.5
MVA=$(curl -sS "$BASE_URL/api/v2/tables/$M2/records?where=(Title,eq,a1)" "${AUTH[@]}" | jq -r '.list[0].Title // empty')
[ "$MVA" = "a1" ] && ok "paused: a1 edit NOT propagated (skip works)" || bad "paused: a1 edit leaked" "$MVA"

say "12. resume + 触发事件 job → 观察补齐水位 job"
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID/resume" "${AUTH[@]}" -o /dev/null
curl -sS -X PATCH "$BASE_URL/api/v2/tables/$T2/records/$RA3" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Title":"a3-edited"}' -o /dev/null
N=0; FOUND=0
while [ $N -lt 60 ]; do
  V=$(curl -sS "$BASE_URL/api/v2/tables/$M2/records?where=(Title,eq,a3-edited)" "${AUTH[@]}" | jq '.list | length')
  [ "$V" = "1" ] && [ $FOUND = 0 ] && { FOUND=1; ok "a3 event job mirrored in ~$((N*500))ms"; }
  # a1 应由补齐水位 job 拉回
  A1V=$(curl -sS "$BASE_URL/api/v2/tables/$M2/records?where=(Title,eq,a1-edited)" "${AUTH[@]}" | jq '.list | length')
  [ "$A1V" = "1" ] && { ok "catch-up watermark pulled a1-edited (final consistency OK)"; CATCHUP=1; break; }
  sleep 0.5; N=$((N+1))
done
[ "${CATCHUP:-0}" = "1" ] || bad "catch-up watermark did NOT pull a1-edited in 30s" ""
say "13. 补齐后 a2(RemoteDeleted) 状态核查 — 水位补齐对 delete 事件的有效性"
A2ROW=$(curl -sS "$BASE_URL/api/v2/tables/$M2/records?where=(Title,eq,a2)" "${AUTH[@]}" | jq -c '.list[0]')
A2DEL=$(echo "$A2ROW" | jq -r '.RemoteDeleted // empty')
if [ "$A2DEL" = "true" ]; then
  ok "a2 RemoteDeleted=true (delete propagated via catch-up)"
elif [ "$A2DEL" = "false" ]; then
  bad "a2 STILL RemoteDeleted=false after catch-up (skipped delete event lost — watermark pull cannot see deleted rows)" "$A2ROW"
else
  bad "a2 row missing in mirror unexpectedly" "$A2ROW"
fi

say "14. 手动 resync 修复核查"
curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID/resync" "${AUTH[@]}" -o /dev/null
for i in $(seq 1 30); do
  ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$DEST_BASE/table-syncs/$S2ID" "${AUTH[@]}")
  [ "$(jqget "$ST" '.status')" = "active" ] && break; sleep 1.5
done
sleep 1
A2DEL2=$(curl -sS "$BASE_URL/api/v2/tables/$M2/records?where=(Title,eq,a2)" "${AUTH[@]}" | jq -r '.list[0].RemoteDeleted // empty')
[ "$A2DEL2" = "true" ] && ok "after manual resync a2 RemoteDeleted=true (full pass heals)" || bad "manual resync did not mark a2" "$A2DEL2"

say "=== SUMMARY ==="
grep -c "^PASS" "$RES" | xargs echo "PASS count:"
grep "^FAIL" "$RES" || echo "no FAIL"
exit 0
