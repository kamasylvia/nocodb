#!/bin/bash
# F02 R2 lane2 part 4: public form via /share endpoint + insert-denial (power< grant)
API=http://localhost:8080
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
TMP=/tmp/f02r2l2
PASS=0; FAIL=0; RESULTS=""
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1 (expect $2 got $3)"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (expect $2 got $3)"; fi; }
code() { local m=$1 u=$2 t=$3 b=$4
  if [ -n "$b" ]; then curl -s -o $TMP/body4 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$b" --max-time 30
  else curl -s -o $TMP/body4 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" --max-time 30; fi; }
anonym() { curl -s -o $TMP/body4 -w '%{http_code}' -X "$1" "$API$2" -H 'Content-Type: application/json' -d "$3" --max-time 30; }

set -a; . ~/.zcode/.env; set +a
T=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
EV=$(infisical secrets --token "$T" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
export PGPASSWORD=$(grep '^DB_PASSWORD=' <<<"$EV" | cut -d= -f2)
DBU=$(grep '^DB_USER=' <<<"$EV" | cut -d= -f2)
q() { $PSQL -h qnap.elf-balance.ts.net -p 5432 -U "$DBU" -d nocodb-dev -At -c "$1"; }

O=$(cat $TMP/tok-owner); TE=$(cat $TMP/tok-editor)
BID=popo6369gr9gwmb; TID=m6pjbuy0l9ryvl7; FVID=vwogusaeo99luko9
SECRET_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret' LIMIT 1")
PHYS="popo6369gr9gwmb.\"T1\""
PERM_URL="/api/v2/meta/bases/$BID/permissions"

# --- insert denial: creator-grant vs editor (power<) ---
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
P7=$(python3 -c 'import json;print(json.load(open("'$TMP'/body4")).get("id",""))')
chk 'grant role=creator (insert round)' 200 "$c"
c=$(code POST "/api/v2/tables/$TID/records" "$TE" '{"Title":"ins-v2","Secret":"x"}')
chk 'v2 insert restricted (editor<creator) 403' 403 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/$TID" "$TE" '{"Title":"ins-v1","Secret":"x"}')
chk 'v1 insert restricted (editor<creator) 403' 403 "$c"
c=$(code DELETE "$PERM_URL/$P7" "$O"); chk 'cleanup creator-grant' 200 "$c"
c=$(code POST "/api/v2/tables/$TID/records" "$TE" '{"Title":"ins-post"}')
chk 'immediacy: v2 insert after delete 200' 200 "$c"

# --- shared form ---
c=$(code POST "/api/v2/meta/views/$FVID/share" "$O")
SHARE_RES=$(cat $TMP/body4 | head -c 200)
UUID=$(q "SELECT uuid FROM nc_views_v2 WHERE id='$FVID'")
RESULTS="$RESULTS\nINFO share-res: $SHARE_RES\nINFO uuid=$UUID"
chkne 'form share uuid generated' '' "$UUID"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
P8=$(python3 -c 'import json;print(json.load(open("'$TMP'/body4")).get("id",""))')
chk 'grant role=editor for form round' 200 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon1","Secret":"leak"}}')
chk 'anon form restricted -> 403 (enforce_for_form default)' 403 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon2"}}')
chk 'anon form w/o restricted -> 200' 200 "$c"
q "UPDATE nc_permissions SET enforce_for_form=false WHERE id='$P8'" >/dev/null
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon3","Secret":"optout"}}')
chk 'anon form enforce_for_form=false -> 200' 200 "$c"
LANDED=$(q "SELECT count(*) FROM $PHYS WHERE title='anon3' AND secret='optout'")
chk 'anon opt-out value landed' 1 "$LANDED"
q "UPDATE nc_permissions SET enforce_for_form=true WHERE id='$P8'" >/dev/null
c=$(code DELETE "$PERM_URL/$P8" "$O"); chk 'cleanup P8' 200 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon4","Secret":"postdel"}}')
chk 'anon after grant delete -> 200 (fail-open)' 200 "$c"

echo -e "$RESULTS" > /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/r2-f02-lane2-out4.txt
echo "== PASS=$PASS FAIL=$FAIL =="
echo -e "$RESULTS"
