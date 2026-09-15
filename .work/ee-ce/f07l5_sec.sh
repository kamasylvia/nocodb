#!/bin/zsh
# f07l5_sec.sh — lane5 补充：副本 purge 降级 error + 非法 title 400
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMAIL="f07l5s_${TS}@ce-ee.local"
PASS="F07l5!pass1"
DBQ() { uv run --with pg8000 python3 "$REPO/.work/ee-ce/f07l5_db.py" qnap.elf-balance.ts.net "$DB_USER" "$DB_PASSWORD" "$@"; }
say() { printf '\n== %s ==\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
JQ() { command jq "$@"; }

set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SEC=$(infisical secrets --token "$TK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; esac; done <<< "$SEC"

TOK=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | JQ -r '.token // empty')
AUTH=(-H "xc-auth: $TOK")
DBQ promote "$EMAIL" > /dev/null
SRC=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"f07l5sec_$TS\"}")
SRC_ID=$(echo "$SRC" | JQ -r '.id'); echo "src=$SRC_ID"

say "S1. 非法 title：非字符串 → 400"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"title":12345}')
[ "$CODE" = "400" ] || fail "title 非字符串应 400, got $CODE"
say "S2. title >512 → 400"
LONG=$(python3 -c "print('x'*600)")
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"title\":\"$LONG\"}")
[ "$CODE" = "400" ] || fail "title 超长应 400, got $CODE"
echo "title guards ok"

say "S3. 建快照 → completed"
SNAP=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}')
SNAP_ID=$(echo "$SNAP" | JQ -r '.id'); COPY_ID=$(echo "$SNAP" | JQ -r '.snapshot_base_id')
for i in $(seq 1 30); do sleep 3; ST=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}" | JQ -r '.status'); [ "$ST" = "completed" ] && break; done
[ "$ST" = "completed" ] || fail "快照未 completed: $ST"
echo "snapshot completed, copy=$COPY_ID"

say "S4. 模拟副本被 trash purge（DB 置 deleted=true）→ 快照降级 error"
uv run --with pg8000 python3 - "$DB_USER" "$DB_PASSWORD" "$COPY_ID" <<'EOF'
import sys
import pg8000.native as pn
con = pn.Connection(user=sys.argv[1], password=sys.argv[2], host="qnap.elf-balance.ts.net", port=5432, database="nocodb-dev")
cid = sys.argv[3].replace("'", "")
con.run(f"UPDATE nc_bases_v2 SET deleted=true, title='[purged] '||title WHERE id='{cid}'")
print("purged", cid)
EOF
sleep 1
ONE=$(curl -sS "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}")
echo "after purge: $ONE"
[ "$(echo "$ONE" | JQ -r '.status')" = "error" ] || fail "副本 purge 后快照应 error: $ONE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID/restore" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}')
[ "$CODE" = "400" ] || fail "副本 purge 后 restore 应 400, got $CODE"
echo "purge degrade ok"

say "S5. 删除降级快照（副本行已 deleted，delete 应容忍）"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID/snapshots/$SNAP_ID" "${AUTH[@]}")
[ "$CODE" = "200" ] || fail "降级快照删除应 200, got $CODE"
N=$(DBQ snaps "$SRC_ID" | JQ 'length')
[ "$N" = "0" ] || fail "快照行未删净: $N"
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$SRC_ID" "${AUTH[@]}" || true
printf '\n== LANE5 SEC ALL PASS ==\n'
