#!/bin/bash
# F02 R2 lane2 part 3: v1 route (table id) + public form (uuid from DB)
API=http://localhost:8080
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
TMP=/tmp/f02r2l2
PASS=0; FAIL=0; RESULTS=""
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1 (expect $2 got $3)"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (expect $2 got $3)"; fi; }
code() { local m=$1 u=$2 t=$3 b=$4
  if [ -n "$b" ]; then curl -s -o $TMP/body3 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$b" --max-time 30
  else curl -s -o $TMP/body3 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" --max-time 30; fi; }
anonym() { curl -s -o $TMP/body3 -w '%{http_code}' -X "$1" "$API$2" -H 'Content-Type: application/json' -d "$3" --max-time 30; }

set -a; . ~/.zcode/.env; set +a
T=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
EV=$(infisical secrets --token "$T" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
export PGPASSWORD=$(grep '^DB_PASSWORD=' <<<"$EV" | cut -d= -f2)
DBU=$(grep '^DB_USER=' <<<"$EV" | cut -d= -f2)
q() { $PSQL -h qnap.elf-balance.ts.net -p 5432 -U "$DBU" -d nocodb-dev -At -c "$1"; }

O=$(cat $TMP/tok-owner); TE=$(cat $TMP/tok-editor)
BID=popo6369gr9gwmb; TID=m6pjbuy0l9ryvl7
SECRET_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret' LIMIT 1")
PHYS=$(q "SELECT schemaname||'.'||relname FROM pg_tables WHERE relname ILIKE 't1' LIMIT 1")
FVID=$(q "SELECT id FROM nc_views_v2 WHERE fk_model_id='$TID' AND type=1 AND title='F2' LIMIT 1")
echo "PHYS=$PHYS FVID=$FVID SECRET_COL=$SECRET_COL"

PERM_URL="/api/v2/meta/bases/$BID/permissions"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
P5=$(python3 -c 'import json;print(json.load(open("'$TMP'/body3")).get("id",""))')
chk 'grant role=editor (v1/form round)' 200 "$c"

# v1 dataAlias insert (nestedInsert path)
c=$(code POST "/api/v1/db/data/v1/$BID/$TID" "$TE" '{"Title":"v1e2","Secret":"v1s"}')
chk 'v1 insert restricted (editor) 403' 403 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/$TID" "$TE" '{"Title":"v1ok2"}')
chk 'v1 insert w/o restricted (editor) 200' 200 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/$TID" "$O" '{"Title":"v1o2","Secret":"v1os"}')
chk 'v1 insert restricted (owner) 200' 200 "$c"

# public shared form
c=$(code PATCH "/api/v2/meta/views/$FVID" "$O" '{"shared":true}')
UUID=$(q "SELECT uuid FROM nc_views_v2 WHERE id='$FVID'")
echo "uuid=$UUID"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon1","Secret":"leak"}}')
chk 'anon form restricted -> 403 (enforce_for_form)' 403 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon2"}}')
chk 'anon form w/o restricted -> 200' 200 "$c"
q "UPDATE nc_permissions SET enforce_for_form=false WHERE id='$P5'" >/dev/null
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon3","Secret":"optout"}}')
chk 'anon form enforce_for_form=false -> 200' 200 "$c"
LANDED=$(q "SELECT count(*) FROM $PHYS WHERE title='anon3' AND secret='optout'")
chk 'anon opt-out value landed' 1 "$LANDED"
q "UPDATE nc_permissions SET enforce_for_form=true WHERE id='$P5'" >/dev/null
# second grant NOT enforcing form, ensure anonymous still blocked by the enforcing one (any-deny on anonymous too)
P6Q=$(q "SELECT count(*) FROM nc_permissions WHERE entity='field' AND entity_id='$SECRET_COL' AND permission='RECORD_FIELD_EDIT'")
chk 'single grant present during anon tests' 1 "$P6Q"
c=$(code DELETE "$PERM_URL/$P5" "$O"); chk 'cleanup P5' 200 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon4","Secret":"postdel"}}')
chk 'anon after grant delete -> 200 (fail-open)' 200 "$c"

echo -e "$RESULTS" > /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/r2-f02-lane2-out3.txt
echo "== PASS=$PASS FAIL=$FAIL =="
echo -e "$RESULTS"
