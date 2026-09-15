#!/usr/bin/env bash
# lane3 F03 run2: DELETE matrix (v2 single/bulk, bulkDeleteAll, v1 delByPk, v3 upsert)
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-env.sh
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
PW='Lane3F03!x'; BID=p2ul0ca5fiabj7k
signin() { curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | jq -r .token; }
OT=$(signin lane3-f03-owner@t.local); ET=$(signin lane3-f03-editor@t.local); CT=$(signin lane3-f03-creator@t.local)
PR=/api/v2/meta/bases/$BID/permissions
N=0; F=0
chk() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS [$3] $1"; else echo "FAIL[exp=$2 got=$3] $1"; F=$((F+1)); fi }
code() { curl -s -o /tmp/lane3-body -w '%{http_code}' "$@"; }
rowid() { curl -s "$API/api/v2/tables/$1/records?where=(Name,eq,$2)" -H "xc-auth: $OT" | jq '.list[0].Id // 0'; }
seed() { curl -s -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"Name\":\"$1\"}" -o /dev/null; }

echo "== F. DELETE nobody on T2 =="
chk "create DELETE nobody grant -> 200" 200 "$(code -X POST $API$PR -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T2\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}")"
seed del-a; ID=$(rowid $T2 del-a)
chk "editor v2 delete single -> 403" 403 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$ID}")"
seed del-b1; seed del-b2
chk "editor v2 delete bulk -> 403" 403 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Id\":$(rowid $T2 del-b1)},{\"Id\":$(rowid $T2 del-b2)}]")"
seed del-v1
chk "editor v1 delByPk -> 403" 403 "$(code -X DELETE $API/api/v1/db/data/noco/$BID/$T2/$(rowid $T2 del-v1) -H "xc-auth: $ET")"
chk "editor v2 deleteAll by filter -> 403" 403 "$(code -X DELETE "$API/api/v1/db/data/bulk/noco/$BID/$T2/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"where":"(Name,like,del-%)"}')"
chk "owner v2 delete single -> 200" 200 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"Id\":$ID}")"

echo "== G. DELETE role:creator =="
GID=$(curl -s $API$PR -H "xc-auth: $OT" | jq -r '.[]|select(.permission=="TABLE_RECORD_DELETE")|.id')
chk "PATCH DELETE grant -> role:creator -> 200" 200 "$(code -X PATCH $API$PR/$GID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}')"
seed delc-e
chk "editor v2 delete -> 403" 403 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$(rowid $T2 delc-e)}")"
chk "creator v2 delete -> 200" 200 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $CT" -H 'Content-Type: application/json' -d "{\"Id\":$(rowid $T2 delc-e)}")"

echo "== H. DELETE role:editor + deleteAll + v3 upsert =="
chk "PATCH DELETE grant -> role:editor -> 200" 200 "$(code -X PATCH $API$PR/$GID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"editor"}')"
seed dele-e
chk "editor v2 delete -> 200" 200 "$(code -X DELETE $API/api/v2/tables/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$(rowid $T2 dele-e)}")"
chk "creator v1 deleteAll -> 200" 200 "$(code -X DELETE "$API/api/v1/db/data/bulk/noco/$BID/$T2/all" -H "xc-auth: $CT" -H 'Content-Type: application/json' -d '{"where":"(Name,like,del-b%)"}')"
echo "-- v3 upsert (ADD on toInsert, ADD grant currently deleted? recreate none):"
chk "DELETE DELETE grant (cleanup) -> 200" 200 "$(code -X DELETE $API$PR/$GID -H "xc-auth: $OT")"
seed up-e
chk "editor v3 upsert pure-update batch (no ADD grant) -> 200" 200 "$(code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-e\",\"Id\":$(rowid $T2 up-e)}]")"
chk "create ADD nobody grant -> 200" 200 "$(code -X POST $API$PR -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T2\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")"
seed up-n1
chk "editor v3 upsert with new row (ADD nobody) -> 403" 403 "$(code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-n1\",\"Id\":$(rowid $T2 up-n1)},{\"Name\":\"up-new-2\"}]")"
G2ID=$(curl -s $API$PR -H "xc-auth: $OT" | jq -r '.[]|select(.permission=="TABLE_RECORD_ADD")|.id')
chk "cleanup ADD grant -> 200" 200 "$(code -X DELETE $API$PR/$G2ID -H "xc-auth: $OT")"
chk "editor v3 upsert pure-update batch (grant gone) -> 200" 200 "$(code -X POST $API/api/v3/data/$T2/records/upsert -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[{\"Name\":\"up-n1b\",\"Id\":$(rowid $T2 up-n1)}]")"
echo "== run2 done: $N checks, $F failures =="
