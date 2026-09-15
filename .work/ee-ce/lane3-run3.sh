#!/usr/bin/env bash
# lane3 F03 run3: VISIBILITY matrix + shadowing
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-env.sh
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-lib.sh
N=0; F=0
echo "== J. VISIBILITY nobody on T2 =="
lg_chk "create VISIBILITY nobody -> 200" 200 "$(lg_code -X POST $API$PR -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T2\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}")"
lg_chk "editor GET meta T2 -> 404" 404 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $ET")"
lg_chk "editor GET data T2 -> 404" 404 "$(lg_code $API/api/v2/tables/$T2/records -H "xc-auth: $ET")"
lg_chk "creator GET meta T2 -> 404" 404 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $CT")"
lg_chk "creator GET data T2 -> 404" 404 "$(lg_code $API/api/v2/tables/$T2/records -H "xc-auth: $CT")"
lg_chk "owner GET meta T2 -> 200" 200 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $OT")"
lg_chk "owner GET data T2 -> 200" 200 "$(lg_code $API/api/v2/tables/$T2/records -H "xc-auth: $OT")"
TBL=$(curl -s $API/api/v2/meta/bases/$BID/tables -H "xc-auth: $ET")
echo "$TBL" | jq -e '.[] | select(.id == "'$T2'")' >/dev/null 2>&1
if [ $? -ne 0 ]; then lg_chk "table list (editor) hides T2" PASS PASS; else lg_chk "table list (editor) hides T2" PASS FAIL; fi
TBL_O=$(curl -s $API/api/v2/meta/bases/$BID/tables -H "xc-auth: $OT")
echo "$TBL_O" | jq -e '.[] | select(.id == "'$T2'")' >/dev/null 2>&1
if [ $? -eq 0 ]; then lg_chk "table list (owner) shows T2" PASS PASS; else lg_chk "table list (owner) shows T2" PASS FAIL; fi

echo "== K. VISIBILITY role:viewer =="
VG=$(lg_gid TABLE_VISIBILITY)
lg_chk "PATCH VISIBILITY -> role:viewer -> 200" 200 "$(lg_code -X PATCH $API$PR/$VG -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"viewer"}')"
lg_chk "editor GET data T2 -> 200" 200 "$(lg_code $API/api/v2/tables/$T2/records -H "xc-auth: $ET")"
lg_chk "creator GET meta T2 -> 200" 200 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $CT")"

echo "== L. VISIBILITY role:creator =="
lg_chk "PATCH VISIBILITY -> role:creator -> 200" 200 "$(lg_code -X PATCH $API$PR/$VG -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}')"
lg_chk "editor GET meta T2 -> 404" 404 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $ET")"
lg_chk "creator GET data T2 -> 200" 200 "$(lg_code $API/api/v2/tables/$T2/records -H "xc-auth: $CT")"

echo "== M. fail-open: delete VISIBILITY grant =="
lg_chk "DELETE VISIBILITY grant -> 200" 200 "$(lg_code -X DELETE $API$PR/$VG -H "xc-auth: $OT")"
lg_chk "editor GET meta T2 -> 200" 200 "$(lg_code $API/api/v2/meta/tables/$T2 -H "xc-auth: $ET")"
lg_chk "anonymous GET data T2 (no share ctx, 401 expected not 500)" 401 "$(lg_code $API/api/v2/tables/$T2/records)"
echo "== run3 done: $N checks, $F failures =="
