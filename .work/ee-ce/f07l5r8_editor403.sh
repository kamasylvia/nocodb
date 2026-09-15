#!/bin/zsh
# f07l5r8_editor403.sh — editor 角色 → snapshots 403 抽查
set -euo pipefail
BASE_URL="http://127.0.0.1:8080"
TS=$(date +%s)
EMA="f07l5r8eda_${TS}@ce-ee.local"   # creator（全小写：nc_users_v2 email 存小写）
EMB="f07l5r8edb_${TS}@ce-ee.local"   # editor
PA="F07l5r8!pass1"; PB="F07l5r8!pass2"
TOKA=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMA\",\"password\":\"$PA\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
TOKB=$(curl -sS -X POST "$BASE_URL/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$EMB\",\"password\":\"$PB\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SEC=$(infisical secrets --token "$TK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""
while IFS='=' read -r k v; do case "$k" in DB_USER) DB_USER="$v";; DB_PASSWORD) DB_PASSWORD="$v";; esac; done <<< "$SEC"
uv run --with pg8000 python3 "$REPO/.work/ee-ce/f07l5r8_db.py" qnap.elf-balance.ts.net 5432 "$DB_USER" "$DB_PASSWORD" promote "$EMA"
B=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases" -H "xc-auth: $TOKA" -H 'Content-Type: application/json' -d "{\"title\":\"f07l5r8ed_$TS\"}")
echo "base resp: $(echo "$B" | head -c 120)"
BID=$(echo "$B" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
# 邀 B 进 base 为 editor
INV=$(curl -sS -X POST "$BASE_URL/api/v2/meta/bases/$BID/users" -H "xc-auth: $TOKA" -H 'Content-Type: application/json' -d "{\"email\":\"$EMB\",\"roles\":\"editor\"}")
echo "invite: $(echo "$INV" | head -c 150)"
C_CREATE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v2/meta/bases/$BID/snapshots" -H "xc-auth: $TOKB" -H 'Content-Type: application/json' -d '{}')
C_LIST=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/snapshots" -H "xc-auth: $TOKB")
C_DELETE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE_URL/api/v2/meta/bases/$BID/snapshots/snapxxx" -H "xc-auth: $TOKB")
echo "editor create=$C_CREATE list=$C_LIST delete=$C_DELETE"
[ "$C_CREATE" = "403" ] && [ "$C_LIST" = "403" ] || { echo "FAIL: editor 应 403"; exit 1; }
# creator 对照组
C_OK=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/api/v2/meta/bases/$BID/snapshots" -H "xc-auth: $TOKA")
echo "creator list=$C_OK"
[ "$C_OK" = "200" ] || { echo "FAIL: creator 应 200"; exit 1; }
curl -sS -o /dev/null -X DELETE "$BASE_URL/api/v2/meta/bases/$BID" -H "xc-auth: $TOKA"
echo "EDITOR-403 PASS"
