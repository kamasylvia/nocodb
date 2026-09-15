#!/bin/bash
# F03 Data permissions — API integration self-test
set -u
API=http://localhost:8080
PSQL_BIN="/opt/homebrew/opt/libpq@18/bin/psql"
PASS=0; FAIL=0
R=$RANDOM
J() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }
OK() { PASS=$((PASS+1)); echo "  ✅ $1"; }
NO() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
PSQL() { PGPASSWORD="$DB_PASSWORD" $PSQL_BIN -h qnap.elf-balance.ts.net -p "${DB_PORT:-5432}" -U "$DB_USER" -d nocodb-dev -t -c "$1"; }

cd /Volumes/UNITEK/Documents/Development/nocodb
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)

EMAIL="f03o$R@t.io"; ED="f03e$R@t.io"; PW='Xx#12345'
curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" > /dev/null
curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$ED\",\"password\":\"$PW\"}" > /dev/null
PSQL "UPDATE nc_users_v2 SET roles='super' WHERE email='$EMAIL';" > /dev/null
OT=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | J "['token']")
AUTH=(-H "xc-auth: $OT" -H 'Content-Type: application/json')
BID=$(curl -s -X POST $API/api/v1/db/meta/projects/ "${AUTH[@]}" -d "{\"title\":\"F03E2E-$R\"}" | J "['id']")
TBL=$(curl -s -X POST $API/api/v2/meta/bases/$BID/tables "${AUTH[@]}" -d '{"table_name":"T1","title":"T1","columns":[{"title":"Name","column_name":"name","uidt":"SingleLineText"}]}')
TID=$(echo "$TBL" | J "['id']")
curl -s -X POST $API/api/v1/db/meta/projects/$BID/users "${AUTH[@]}" -d "{\"email\":\"$ED\",\"roles\":\"editor\"}" > /dev/null
ET=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$ED\",\"password\":\"$PW\"}" | J "['token']")
EAUTH=(-H "xc-auth: $ET" -H 'Content-Type: application/json')
echo "base=$BID table=$TID"

echo "== 1. fail-open (no table grants) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Name":"r1"}')
[ "$CODE" = "200" ] && OK "editor insert no grant -> 200" || NO "editor insert -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Id":1,"Name":"r1b"}')
[ "$CODE" = "200" ] && OK "editor update no grant -> 200" || NO "editor update -> $CODE"

echo "== 2. ADD grant lifecycle =="
ADDID=$(curl -s -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}" | J "['id']")
[ -n "$ADDID" ] && OK "create ADD nobody grant" || NO "create ADD grant"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Name":"r2"}')
[ "$CODE" = "403" ] && OK "editor insert with ADD-nobody -> 403" || NO "editor insert ADD -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Id":1,"Name":"r1c"}')
[ "$CODE" = "200" ] && OK "editor update unaffected -> 200" || NO "editor update -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Name":"r2"}')
[ "$CODE" = "200" ] && OK "owner insert unaffected -> 200" || NO "owner insert -> $CODE"
# role=creator grant
curl -s -o /dev/null -X PATCH $API/api/v2/meta/bases/$BID/permissions/$ADDID "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}'
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Name":"r3"}')
[ "$CODE" = "403" ] && OK "editor insert (creator-role) -> 403" || NO "editor insert creator-role -> $CODE"

echo "== 3. DELETE grant =="
DELID=$(curl -s -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}" | J "['id']")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $API/api/v2/tables/$TID/records "${EAUTH[@]}" -H 'Content-Type: application/json' -d '{"Id":1}')
[ "$CODE" = "403" ] && OK "editor delete with DELETE-nobody -> 403" || NO "editor delete -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $API/api/v2/tables/$TID/records "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Id":1}')
[ "$CODE" = "200" ] && OK "owner delete unaffected -> 200" || NO "owner delete -> $CODE"
curl -s -o /dev/null -X DELETE $API/api/v2/meta/bases/$BID/permissions/$DELID "${AUTH[@]}"

echo "== 4. VISIBILITY grant =="
VISID=$(curl -s -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}" | J "['id']")
CODE=$(curl -s -o /dev/null -w '%{http_code}' $API/api/v2/meta/tables/$TID "${EAUTH[@]}")
[ "$CODE" = "404" ] && OK "editor meta hidden (404)" || NO "editor meta -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' $API/api/v2/tables/$TID/records "${EAUTH[@]}")
[ "$CODE" = "404" ] && OK "editor data route hidden (404)" || NO "editor data -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' $API/api/v2/meta/tables/$TID "${AUTH[@]}")
[ "$CODE" = "200" ] && OK "owner meta visible -> 200" || NO "owner meta -> $CODE"
# Everyone = delete grant
curl -s -o /dev/null -X DELETE $API/api/v2/meta/bases/$BID/permissions/$VISID "${AUTH[@]}"
CODE=$(curl -s -o /dev/null -w '%{http_code}' $API/api/v2/meta/tables/$TID "${EAUTH[@]}")
[ "$CODE" = "200" ] && OK "delete VISIBILITY grant restores -> 200" || NO "restore -> $CODE"

echo "== 5. 校验对称 =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
[ "$CODE" = "400" ] && OK "table entity + FIELD key -> 400" || NO "cross key -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")
[ "$CODE" = "400" ] && OK "below minimumRole -> 400" || NO "minimumRole -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
CODE2=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
[ "$CODE2" = "400" ] && OK "duplicate grant -> 400" || NO "duplicate -> $CODE2"

echo "== 6. base 删除级联 =="
curl -s -o /dev/null -X DELETE $API/api/v2/meta/bases/$BID "${AUTH[@]}"
LEFT=$(PSQL "SELECT count(*) FROM nc_permissions WHERE base_id='$BID';" | xargs)
[ "$LEFT" = "0" ] && OK "base delete cascades permissions" || NO "cascade left $LEFT rows"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
