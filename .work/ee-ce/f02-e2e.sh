#!/bin/bash
# F02 Edit field permissions — API integration self-test (fork)
set -u
API=http://localhost:8080
PSQL_BIN="/opt/homebrew/opt/libpq@18/bin/psql"
PASS=0; FAIL=0
R=$RANDOM
J() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }
OK() { PASS=$((PASS+1)); echo "  ✅ $1"; }
NO() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

cd /Volumes/UNITEK/Documents/Development/nocodb
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
PSQL() { PGPASSWORD="$DB_PASSWORD" $PSQL_BIN -h qnap.elf-balance.ts.net -p "${DB_PORT:-5432}" -U "$DB_USER" -d nocodb-dev -t -c "$1"; }

signup() { # email -> token stdout
  curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"Xx#12345\"}" > /dev/null
  curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"Xx#12345\"}" | J "['token']"
}

echo "== setup: owner / editor / editor2 =="
OWNER="f02o$R@t.io"; ED1="f02e1$R@t.io"; ED2="f02e2$R@t.io"; PW='Xx#12345'
curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$OWNER\",\"password\":\"$PW\"}" > /dev/null
curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$ED1\",\"password\":\"$PW\"}" > /dev/null
curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$ED2\",\"password\":\"$PW\"}" > /dev/null
PSQL "UPDATE nc_users_v2 SET roles='super' WHERE email='$OWNER';" > /dev/null
OTOKEN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$OWNER\",\"password\":\"$PW\"}" | J "['token']")
AUTH=(-H "xc-auth: $OTOKEN" -H 'Content-Type: application/json')

BID=$(curl -s -X POST $API/api/v1/db/meta/projects/ "${AUTH[@]}" -d "{\"title\":\"F02E2E-$R\"}" | J "['id']")
TBL=$(curl -s -X POST $API/api/v2/meta/bases/$BID/tables "${AUTH[@]}" -d '{"table_name":"T1","title":"T1","columns":[{"title":"Name","column_name":"name","uidt":"SingleLineText"},{"title":"Secret","column_name":"secret","uidt":"SingleLineText"}]}')
TID=$(echo "$TBL" | J "['id']")
NAMEID=$(echo "$TBL" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Name'][0])")
SECID=$(echo "$TBL" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Secret'][0])")
echo "base=$BID table=$TID name=$NAMEID secret=$SECID"

# invite editor via API (existing user invite) then verify roles from DB
curl -s -X POST $API/api/v1/db/meta/projects/$BID/users "${AUTH[@]}" -d "{\"email\":\"$ED1\",\"roles\":\"editor\"}" > /tmp/f02inv1
curl -s -X POST $API/api/v1/db/meta/projects/$BID/users "${AUTH[@]}" -d "{\"email\":\"$ED2\",\"roles\":\"editor\"}" > /tmp/f02inv2
E1ID=$(PSQL "SELECT id FROM nc_users_v2 WHERE email='$ED1';" | xargs)
E2ID=$(PSQL "SELECT id FROM nc_users_v2 WHERE email='$ED2';" | xargs)
PSQL "UPDATE nc_base_users_v2 SET roles='editor' WHERE fk_user_id IN ('$E1ID','$E2ID');" > /dev/null
ET1=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$ED1\",\"password\":\"$PW\"}" | J "['token']")
ET2=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$ED2\",\"password\":\"$PW\"}" | J "['token']")
EAUTH1=(-H "xc-auth: $ET1" -H 'Content-Type: application/json')
EAUTH2=(-H "xc-auth: $ET2" -H 'Content-Type: application/json')
echo "invited editors: $E1ID $E2ID"

# insert a record as owner
ROW=$(curl -s -X POST $API/api/v2/tables/$TID/records "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Name":"r1","Secret":"s1"}')
RID=$(echo "$ROW" | J "['Id']")
echo "row=$RID"

echo "== 1. fail-open (no grants) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Name":"r1b"}')
[ "$CODE" = "200" ] && OK "editor update with no grants -> 200" || NO "editor update no grants -> $CODE (want 200)"

echo "== 2. permissions CRUD =="
CODE=$(curl -s -o /tmp/f02c -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
PID=$(J "['id']" < /tmp/f02c)
[ "$CODE" = "200" ] && [ -n "$PID" ] && OK "create nobody grant -> 200 id=$PID" || NO "create nobody grant -> $CODE"
CODE=$(curl -s -o /tmp/f02l -w '%{http_code}' $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}")
CNT=$(python3 -c "import json;d=json.load(open('/tmp/f02l'));print(len(d))")
[ "$CODE" = "200" ] && [ "$CNT" -ge 1 ] && OK "list -> 200 ($CNT rows)" || NO "list -> $CODE ($CNT rows)"
CODE=$(curl -s -o /tmp/f02bad -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"entity":"field","entity_id":"nope","permission":"RECORD_FIELD_EDIT","granted_type":"nobody"}')
[ "$CODE" = "400" ] && OK "create with bogus column -> 400" || NO "bogus column -> $CODE (want 400)"

echo "== 3. enforcement (nobody grant on Secret) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"x"}')
[ "$CODE" = "403" ] && OK "editor update restricted field -> 403" || NO "editor restricted -> $CODE (want 403)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Name":"r1c"}')
[ "$CODE" = "200" ] && OK "editor update other field -> 200" || NO "editor other field -> $CODE (want 200)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"s2"}')
[ "$CODE" = "200" ] && OK "owner update restricted field -> 200" || NO "owner restricted -> $CODE (want 200)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Name":"r2","Secret":"sx"}')
[ "$CODE" = "403" ] && OK "editor insert with restricted field -> 403" || NO "editor insert restricted -> $CODE (want 403)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Name":"r2"}')
[ "$CODE" = "200" ] && OK "editor insert without restricted field -> 200" || NO "editor insert clean -> $CODE (want 200)"

echo "== 4. bulk paths =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '[{"Name":"b1","Secret":"bx"}]')
[ "$CODE" = "403" ] && OK "editor bulkUpdate(insert/upsert style) with restricted -> 403" || NO "bulk restricted -> $CODE (want 403)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '[{"Name":"b1"}]')
[ "$CODE" = "200" ] && OK "editor bulk insert clean -> 200" || NO "bulk clean -> $CODE (want 200)"

echo "== 5. role grant (creator) =="
CODE=$(curl -s -o /tmp/f02p -w '%{http_code}' -X PATCH $API/api/v2/meta/bases/$BID/permissions/$PID "${AUTH[@]}" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}')
[ "$CODE" = "200" ] && OK "patch grant to creator role -> 200" || NO "patch grant -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"x"}')
[ "$CODE" = "403" ] && OK "editor still denied -> 403" || NO "editor denied -> $CODE"

echo "== 6. user grant =="
curl -s -X PATCH $API/api/v2/meta/bases/$BID/permissions/$PID "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$E1ID\"}]}" > /dev/null
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"ok1"}')
[ "$CODE" = "200" ] && OK "granted editor can edit -> 200" || NO "granted editor -> $CODE (want 200)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH2[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"no1"}')
[ "$CODE" = "403" ] && OK "non-granted editor denied -> 403" || NO "non-granted editor -> $CODE (want 403)"

echo "== 7. delete grant -> fail-open restored =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $API/api/v2/meta/bases/$BID/permissions/$PID "${AUTH[@]}")
[ "$CODE" = "200" ] && OK "delete grant -> 200" || NO "delete grant -> $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH2[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"free"}')
[ "$CODE" = "200" ] && OK "editor update after reset -> 200" || NO "after reset -> $CODE (want 200)"

echo "== 8. cache invalidation (create -> immediate deny) =="
PID2=$(curl -s -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" | J "['id']")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH $API/api/v2/tables/$TID/records "${EAUTH2[@]}" -H 'Content-Type: application/json' -d '{"Id":'"$RID"',"Secret":"z"}')
[ "$CODE" = "403" ] && OK "fresh grant denies next request -> 403" || NO "fresh grant -> $CODE (want 403)"
curl -s -X DELETE $API/api/v2/meta/bases/$BID/permissions/$PID2 "${AUTH[@]}" > /dev/null

echo "== 9. R1 fixes regression =="
# ensure a nobody grant exists for the bypass tests
GRANT_ID=$(curl -s -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" | J "['id']")

# v1 data insert route must NOT bypass restricted field (nestedInsert hook)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v1/db/data/noco/$BID/$TID "${EAUTH1[@]}" -H 'Content-Type: application/json' -d '{"Name":"v1x","Secret":"v1s"}')
[ "$CODE" = "403" ] && OK "v1 insert restricted -> 403" || NO "v1 insert restricted -> $CODE (want 403)"
# duplicate grant rejection (same field/permission as the grant above)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
[ "$CODE" = "400" ] && OK "duplicate grant -> 400" || NO "duplicate grant -> $CODE (want 400)"
# bogus granted_role rejection
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAMEID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"bogusr\"}")
[ "$CODE" = "400" ] && OK "bogus granted_role -> 400" || NO "bogus granted_role -> $CODE (want 400)"
# below-minimumRole rejection
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $API/api/v2/meta/bases/$BID/permissions "${AUTH[@]}" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAMEID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")
[ "$CODE" = "400" ] && OK "below-minimumRole viewer -> 400" || NO "viewer grant -> $CODE (want 400)"

# cleanup the nobody grant so later duplicate tests start clean
curl -s -o /dev/null -X DELETE $API/api/v2/meta/bases/$BID/permissions/$GRANT_ID "${AUTH[@]}"

echo "== cleanup =="
curl -s -o /dev/null -X DELETE $API/api/v2/meta/bases/$BID "${AUTH[@]}"
PSQL "DELETE FROM nc_base_users_v2 WHERE fk_user_id IN ('$E1ID','$E2ID');" > /dev/null
echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
