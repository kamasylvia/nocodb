#!/bin/bash
set -e
cd /Volumes/UNITEK/Documents/Development/nocodb
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
SEC=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=$(echo "$SEC" | grep '^DB_USER=' | cut -d= -f2-)
DB_PASS=$(echo "$SEC" | grep '^DB_PASSWORD=' | cut -d= -f2-)
PSQL="/opt/homebrew/opt/libpq@18/bin/psql"
API=http://localhost:8080
EMAIL_O=f02r1l4-owner@test.local
EMAIL_E=f02r1l4-editor@test.local
PW='F02r1l4!Pass9'

# 1. signup owner + editor (idempotent-ish: ignore already exists)
curl -s -X POST $API/api/v1/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_O\",\"password\":\"$PW\"}" > /tmp/f02r1l4_o_signup.json || true
curl -s -X POST $API/api/v1/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_E\",\"password\":\"$PW\"}" > /tmp/f02r1l4_e_signup.json || true
echo "signup-owner: $(cat /tmp/f02r1l4_o_signup.json | head -c 200)"
echo "signup-editor: $(cat /tmp/f02r1l4_e_signup.json | head -c 200)"

# 2. promote owner to super + verify emails verified (invitation flow needs it)
PGPASSWORD="$DB_PASS" $PSQL -h qnap.elf-balance.ts.net -U "$DB_USER" -d nocodb-dev -t -c \
  "UPDATE nc_users_v2 SET roles='super', email_verified=true, invite_token=NULL WHERE email IN ('$EMAIL_O','$EMAIL_E'); SELECT email, roles FROM nc_users_v2 WHERE email LIKE 'f02r1l4-%';"

# 3. signin owner
OT=$(curl -s -X POST $API/api/v1/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_O\",\"password\":\"$PW\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
echo "owner-token-len: ${#OT}"

# 4. create base
BID=$(curl -s -X POST $API/api/v1/db/meta/bases/ -H "xc-token: $OT" -H 'Content-Type: application/json' -d '{"title":"f02r1l4-base"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "base: $BID"

# 5. create table with Name/Secret/Price
TRES=$(curl -s -X POST $API/api/v1/db/meta/bases/$BID/tables -H "xc-token: $OT" -H 'Content-Type: application/json' \
  -d '{"table_name":"Data","columns":[{"column_name":"Name","uidt":"SingleLineText"},{"column_name":"Secret","uidt":"SingleLineText"},{"column_name":"Price","uidt":"Number"}]}')
TID=$(echo "$TRES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "table: $TID"

# 6. insert 2 records
curl -s -X POST $API/api/v2/tables/$TID/records -H "xc-token: $OT" -H 'Content-Type: application/json' -d '{"Name":"alpha","Secret":"s1","Price":10}' | head -c 150; echo
curl -s -X POST $API/api/v2/tables/$TID/records -H "xc-token: $OT" -H 'Content-Type: application/json' -d '{"Name":"beta","Secret":"s2","Price":20}' | head -c 150; echo

# 7. invite editor into base
curl -s -X POST $API/api/v2/meta/bases/$BID/users -H "xc-token: $OT" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_E\",\"roles\":\"editor\"}" | head -c 300; echo

# 8. editor signin token (for later API cross-check)
ET=$(curl -s -X POST $API/api/v1/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL_E\",\"password\":\"$PW\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
echo "editor-token-len: ${#ET}"

# 9. get Secret column id
curl -s "$API/api/v2/meta/bases/$BID/tables/$TID" -H "xc-token: $OT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(c["id"]+"="+c["title"]+"("+c["uidt"]+")" for c in d["columns"]))'

echo "BASE=$BID" > /tmp/f02r1l4_state
echo "TABLE=$TID" >> /tmp/f02r1l4_state
echo "OWNER_TOKEN=$OT" >> /tmp/f02r1l4_state
echo "EDITOR_TOKEN=$ET" >> /tmp/f02r1l4_state
echo "PW=$PW" >> /tmp/f02r1l4_state
echo "EMAIL_O=$EMAIL_O" >> /tmp/f02r1l4_state
echo "EMAIL_E=$EMAIL_E" >> /tmp/f02r1l4_state
