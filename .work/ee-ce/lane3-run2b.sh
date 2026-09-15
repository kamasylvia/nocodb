#!/usr/bin/env bash
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-env.sh
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-lib.sh
N=0; F=0
GID=$(lg_gid TABLE_RECORD_DELETE); echo "DELETE grant id=$GID"
echo "== G'. DELETE role:creator =="
lg_chk "PATCH -> role:creator -> 200" 200 "$(lg_code -X PATCH $API$PR/$GID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}')"
lg_seed delc-e; E1=$(lg_rowid $T2 delc-e)
lg_chk "editor v2 delete -> 403" 403 "$(lg_code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$E1}")"
lg_chk "creator v2 delete -> 200" 200 "$(lg_code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $CT" -H 'Content-Type: application/json' -d "{\"Id\":$E1}")"
echo "== H'. DELETE role:editor =="
lg_chk "PATCH -> role:editor -> 200" 200 "$(lg_code -X PATCH $API$PR/$GID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"editor"}')"
lg_seed dele-e; E2=$(lg_rowid $T2 dele-e)
lg_chk "editor v2 delete -> 200" 200 "$(lg_code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$E2}")"
lg_seed dele-v1; E3=$(lg_rowid $T2 dele-v1)
lg_chk "creator v1 delByPk -> 200" 200 "$(lg_code -X DELETE $API/api/v1/db/data/noco/$BID/$T2/$E3 -H "xc-auth: $CT")"
lg_chk "editor deleteAll by filter -> 200" 200 "$(lg_code -X DELETE "$API/api/v1/db/data/bulk/noco/$BID/$T2/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"where":"(Name,like,del-b%)"}')"
echo "== I'. v3 upsert split semantics =="
lg_chk "DELETE DELETE grant -> 200" 200 "$(lg_code -X DELETE $API$PR/$GID -H "xc-auth: $OT")"
lg_seed up-e; UE=$(lg_rowid $T2 up-e)
lg_chk "editor v3 upsert pure-update (no ADD grant) -> 200" 200 "$(lg_code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-e2\",\"Id\":$UE}]")"
lg_chk "create ADD nobody grant -> 200" 200 "$(lg_code -X POST $API$PR -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T2\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")"
lg_seed up-n1; UN=$(lg_rowid $T2 up-n1)
lg_chk "editor v3 upsert mixed batch (update+insert, ADD nobody) -> 403" 403 "$(lg_code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-n1b\",\"Id\":$UN},{\"Name\":\"up-new2\"}]")"
AID=$(lg_gid TABLE_RECORD_ADD)
lg_chk "cleanup ADD grant -> 200" 200 "$(lg_code -X DELETE $API$PR/$AID -H "xc-auth: $OT")"
lg_chk "editor v3 upsert pure-update (grant gone) -> 200" 200 "$(lg_code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-n1c\",\"Id\":$UN}]")"
echo "== run2b done: $N checks, $F failures =="
