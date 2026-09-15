#!/usr/bin/env bash
# lane3 F03 run1: fail-open baseline + ADD matrix
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-env.sh
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
PW='Lane3F03!x'; BID=p2ul0ca5fiabj7k
signin() { curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | jq -r .token; }
OT=$(signin lane3-f03-owner@t.local); ET=$(signin lane3-f03-editor@t.local); CT=$(signin lane3-f03-creator@t.local)
PR=/api/v2/meta/bases/$BID/permissions
DR2=/api/v2/tables
N=0; F=0
chk() { # chk <desc> <expected> <actual-code>
  N=$((N+1))
  if [ "$2" = "$3" ]; then echo "PASS [$3] $1"; else echo "FAIL[exp=$2 got=$3] $1"; F=$((F+1)); fi
}
code() { curl -s -o /tmp/lane3-body -w '%{http_code}' "$@"; }

echo "== seed records (owner) =="
for i in 1 2 3 4; do code -X POST $API$DR2/$T1/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"Name\":\"seed-$i\"}" >/dev/null; done
code -X POST $API$DR2/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Name":"t2-seed"}' >/dev/null

echo "== A. fail-open: no grants anywhere =="
chk "editor insert T1 (no grant) -> 200" 200 "$(code -X POST $API$DR2/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"ff-e"}')"
chk "editor delete T1 row (no grant) -> 200" 200 "$(code -X DELETE $API$DR2/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$(curl -s "$API$DR2/$T1/records?where=(Name,eq,ff-e)" -H "xc-auth: $ET" | jq '.list[0].Id')}")"
chk "editor GET T2 data (no grant) -> 200" 200 "$(code $API$DR2/$T2/records -H "xc-auth: $ET")"
chk "creator GET meta T2 (no grant) -> 200" 200 "$(code $API/api/v2/meta/tables/$T2 -H "xc-auth: $CT")"

echo "== B. ADD grant nobody on T2 =="
G1=$(code -X POST $API$PR -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T2\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk "create ADD nobody grant -> 200" 200 "$G1"
chk "editor insert T2 -> 403" 403 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"deny-e"}')"
chk "creator insert T2 -> 403" 403 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"deny-c"}')"
chk "owner insert T2 -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Name":"ok-o"}')"
chk "editor bulk insert T2 -> 403" 403 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Name":"bulk-e1"},{"Name":"bulk-e2"}]')"
chk "editor update T2 (ADD not involved) -> 200" 200 "$(code -X PATCH $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$(curl -s "$API$DR2/$T2/records?where=(Name,eq,t2-seed)" -H "xc-auth: $ET" | jq '.list[0].Id'),\"Name\":\"t2-seed-ed\"}")"
chk "editor delete T2 row (DELETE not involved) -> 200" 200 "$(code -X DELETE $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"Id\":$(curl -s "$API$DR2/$T2/records?where=(Name,eq,t2-seed-ed)" -H "xc-auth: $ET" | jq '.list[0].Id')}")"

echo "== C. switch ADD grant to role:creator =="
G1ID=$(curl -s $API$PR -H "xc-auth: $OT" | jq -r '.[]|select(.permission=="TABLE_RECORD_ADD" and .entity_id=="'$T2'")|.id')
chk "PATCH ADD grant -> role:creator -> 200" 200 "$(code -X PATCH $API$PR/$G1ID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"creator"}')"
chk "editor insert T2 -> 403" 403 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"rc-e"}')"
chk "creator insert T2 -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $CT" -H 'Content-Type: application/json' -d '{"Name":"rc-c"}')"
chk "creator bulk insert T2 -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $CT" -H 'Content-Type: application/json' -d '[{"Name":"rc-bulk1"}]')"

echo "== D. switch ADD grant to role:editor =="
chk "PATCH ADD grant -> role:editor -> 200" 200 "$(code -X PATCH $API$PR/$G1ID -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"editor"}')"
chk "editor insert T2 -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"re-e"}')"
chk "creator insert T2 -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $CT" -H 'Content-Type: application/json' -d '{"Name":"re-c"}')"

echo "== E. fail-open after grant delete =="
chk "DELETE ADD grant -> 200" 200 "$(code -X DELETE $API$PR/$G1ID -H "xc-auth: $OT")"
chk "editor insert T2 (grant gone) -> 200" 200 "$(code -X POST $API$DR2/$T2/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Name":"fo-e"}')"
echo "== run1 done: $N checks, $F failures =="
