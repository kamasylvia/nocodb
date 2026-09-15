#!/bin/zsh
# int-lane3-f07.sh — F07 snapshots 全生命周期集成测试（lane3, r5）
# 凭证运行时从 Infisical KDL 拉取，不落盘。严禁 nocodb 生产库，只用 nocodb-dev。
set -uo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
API="http://localhost:8080"
EMAIL="lane3f07@eetest.local"
PASS='Xk9#mP2$vL8q'
RES="/tmp/f07-lane3-int-results.txt"
: > "$RES"
ok()   { echo "PASS: $1" >> "$RES"; }
fail() { echo "FAIL: $1" >> "$RES"; }

# ---- DB 凭证 ----
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""; DB_PORT="5432"
while IFS='=' read -r k v; do
  case "$k" in
    DB_USER) DB_USER="$v";;
    DB_PASSWORD) DB_PASSWORD="$v";;
    DB_PORT) DB_PORT="$v";;
  esac
done <<< "$SECRETS"
export DB_USER DB_PASSWORD DB_PORT
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || { echo "FAIL: DB 凭证拉取" >> "$RES"; cat "$RES"; exit 1; }

dbq() {  # dbq "<sql>" — 单值查询
  uv run --with pg8000 python3 - "$1" <<'PYEOF'
import sys, os, pg8000.native
sql = sys.argv[1]
con = pg8000.native.Connection(
    user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
    host="qnap.elf-balance.ts.net", port=int(os.environ.get("DB_PORT","5432")), database="nocodb-dev")
rows = con.run(sql)
con.close()
if rows and rows[0] is not None:
    v = rows[0][0]
    print(v if not isinstance(v, (bytes, bytearray)) else v.decode())
else:
    print("NULL")
PYEOF
}

# ---- auth ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/api/v1/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
if [ "$code" = "200" ]; then
  TOKEN=$(curl -s -X POST "$API/api/v1/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
else
  TOKEN=$(curl -s -X POST "$API/api/v1/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
fi
[ -n "$TOKEN" ] && ok "auth token" || { fail "auth token (empty)"; cat "$RES"; exit 1; }
AH="xc-auth: $TOKEN"

# ---- 建 base ----
BASE=$(curl -s -X POST "$API/api/v2/meta/bases" -H "$AH" -H 'Content-Type: application/json' -d '{"title":"LANE3-F07-SRC"}' | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("id",""))')
[ -n "$BASE" ] && ok "create base $BASE" || { fail "create base"; cat "$RES"; exit 1; }

# ---- 边界: title 非 string ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H "$AH" -H 'Content-Type: application/json' -d '{"title":12345}')
[ "$code" = "400" ] && ok "title non-string -> 400" || fail "title non-string got $code (expect 400)"

# ---- 边界: title >512 ----
LONG=$(python3 -c 'print("x"*513)')
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H "$AH" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$code" = "400" ] && ok "title >512 -> 400" || fail "title >512 got $code (expect 400)"

# ---- 边界: restore 不存在 snapshot ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/api/v2/meta/bases/$BASE/snapshots/no-such-id/restore" -H "$AH")
[ "$code" = "404" ] && ok "restore unknown snapshot -> 404" || fail "restore unknown got $code (expect 404)"

# ---- 边界: 未认证 ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H 'Content-Type: application/json' -d '{}')
[ "$code" = "401" ] && ok "unauthenticated create -> 401" || fail "unauthenticated got $code (expect 401)"

# ---- 快照 #1: 默认 title ----
S1=$(curl -s -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H "$AH" -H 'Content-Type: application/json' -d '{}')
S1ID=$(echo "$S1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
S1TITLE=$(echo "$S1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("title",""))' 2>/dev/null)
S1STATUS=$(echo "$S1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
[ -n "$S1ID" ] && ok "create snapshot1 id=$S1ID" || { fail "create snapshot1: $S1"; cat "$RES"; exit 1; }
case "$S1TITLE" in Snapshot\ *) ok "default title format ($S1TITLE)";; *) fail "default title: $S1TITLE";; esac
[ "$S1STATUS" = "processing" ] && ok "initial status processing" || fail "initial status: $S1STATUS"

# ---- poll to completed ----
ST=""
for i in $(seq 1 24); do
  sleep 5
  ST=$(curl -s "$API/api/v2/meta/bases/$BASE/snapshots/$S1ID" -H "$AH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
  [ "$ST" = "completed" ] && break
  [ "$ST" = "error" ] && break
done
[ "$ST" = "completed" ] && ok "snapshot1 completed" || fail "snapshot1 final status=$ST (expect completed)"

# ---- restore ----
R=$(curl -s -X POST "$API/api/v2/meta/bases/$BASE/snapshots/$S1ID/restore" -H "$AH")
RID=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("base_id",""))' 2>/dev/null)
[ -n "$RID" ] && ok "restore -> base $RID" || fail "restore: $R"

# ---- 快照 #2: 自定义 title，留给删源 base 清理核验 ----
S2=$(curl -s -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H "$AH" -H 'Content-Type: application/json' -d '{"title":"lane3-keep"}')
S2ID=$(echo "$S2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
S2BASE=$(echo "$S2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("snapshot_base_id",""))' 2>/dev/null)
[ -n "$S2ID" ] && ok "create snapshot2 id=$S2ID" || fail "create snapshot2: $S2"
# 1 号快照处理中 mutex 抽验已被轮询消解; S2 poll
ST2=""
for i in $(seq 1 24); do
  sleep 5
  ST2=$(curl -s "$API/api/v2/meta/bases/$BASE/snapshots/$S2ID" -H "$AH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
  [ "$ST2" = "completed" ] && break
  [ "$ST2" = "error" ] && break
done
[ "$ST2" = "completed" ] && ok "snapshot2 completed" || fail "snapshot2 final status=$ST2"
[ -n "$S2BASE" ] || fail "snapshot2 snapshot_base_id empty"

# ---- DB 预核: 快照行存在 ----
cnt=$(dbq "SELECT count(*) FROM nc_snapshots WHERE base_id='$BASE'")
[ "$cnt" = "2" ] && ok "DB: 2 snapshot rows before cleanup" || fail "DB: snapshot rows=$cnt (expect 2)"

# ---- 删快照 #1 ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API/api/v2/meta/bases/$BASE/snapshots/$S1ID" -H "$AH")
[ "$code" = "200" ] && ok "delete snapshot1 -> 200" || fail "delete snapshot1 got $code"
S1DEL=$(dbq "SELECT count(*) FROM nc_snapshots WHERE id='$S1ID'")
[ "$S1DEL" = "0" ] && ok "DB: snapshot1 row gone" || fail "DB: snapshot1 row still present ($S1DEL)"

# ---- 删快照 #2 (直接删, 验证行+副本) ----
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API/api/v2/meta/bases/$BASE/snapshots/$S2ID" -H "$AH")
[ "$code" = "200" ] && ok "delete snapshot2 -> 200" || fail "delete snapshot2 got $code"
S2DEL=$(dbq "SELECT count(*) FROM nc_snapshots WHERE id='$S2ID'")
[ "$S2DEL" = "0" ] && ok "DB: snapshot2 row gone" || fail "DB: snapshot2 row still present"
S2COPY=$(dbq "SELECT deleted FROM nc_bases_v2 WHERE id='$S2BASE'")
[ "$S2COPY" = "true" ] && ok "DB: snapshot2 copy base soft-deleted" || fail "DB: snapshot2 copy deleted=$S2COPY (expect true)"

# ---- 删源 base -> cleanup 核验 ----
# 先留一个快照行在库（重建 S3，不等完成也无妨——cleanup 不看状态）
S3=$(curl -s -X POST "$API/api/v2/meta/bases/$BASE/snapshots" -H "$AH" -H 'Content-Type: application/json' -d '{"title":"lane3-cleanup-probe"}')
S3ID=$(echo "$S3" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
S3BASE=$(echo "$S3" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("snapshot_base_id",""))' 2>/dev/null)
[ -n "$S3ID" ] && ok "create snapshot3 for cleanup probe id=$S3ID" || fail "create snapshot3: $S3"

code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API/api/v2/meta/bases/$BASE" -H "$AH")
[ "$code" = "200" ] && ok "delete source base -> 200" || fail "delete source base got $code"
sleep 3
LEFT=$(dbq "SELECT count(*) FROM nc_snapshots WHERE base_id='$BASE'")
[ "$LEFT" = "0" ] && ok "DB: all snapshot rows cleaned after source base delete" || fail "DB: $LEFT snapshot rows remain after source base delete"
S3COPYDEL=$(dbq "SELECT COALESCE(deleted::text,'NULL') FROM nc_bases_v2 WHERE id='$S3BASE'")
[ "$S3COPYDEL" = "true" ] && ok "DB: snapshot3 copy base soft-deleted by cleanup" || fail "DB: snapshot3 copy deleted=$S3COPYDEL (expect true)"
SRCDEL=$(dbq "SELECT deleted::text FROM nc_bases_v2 WHERE id='$BASE'")
[ "$SRCDEL" = "true" ] && ok "DB: source base soft-deleted" || fail "DB: source base deleted=$SRCDEL"
RIDOK=$(dbq "SELECT COALESCE(deleted::text,'GONE') FROM nc_bases_v2 WHERE id='$RID'")
[ "$RIDOK" = "false" ] && ok "DB: restored base alive (not touched by cleanup)" || fail "DB: restored base state=$RIDOK (expect false)"

# ---- 清理 restored base ----
curl -s -o /dev/null -X DELETE "$API/api/v2/meta/bases/$RID" -H "$AH"

echo "=== RESULTS ==="
cat "$RES"
echo "=== SUMMARY: $(grep -c '^PASS' "$RES") pass / $(grep -c '^FAIL' "$RES") fail ==="
