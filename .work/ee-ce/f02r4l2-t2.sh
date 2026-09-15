#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
AC=$F02R4L2_AMOUNT_COL
# editor token
ETOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-editor@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
req() { local m=$1 p=$2 body=$3 tok=$4
  local out=$(curl -s -w $'\n%{http_code}' -X $m "$B$p" -H "xc-auth: ${tok:-$F02R4L2_TOK}" -H 'Content-Type: application/json' ${body:+-d "$body"})
  echo "$out" | /usr/bin/python3 -c 'import sys;d=sys.stdin.read().split("\n");print(d[-1], " ".join(d[:-1])[:120])'
}
state() { $DBQ "select granted_type, coalesce(granted_role,'-'), (select count(*) from nc_permission_subjects s where s.fk_permission_id=p.id) from nc_permissions p where p.entity_id='$AC';"; }
# editor edits Amount on record 1 (immediacy probe)
ed() { req PATCH /api/v2/tables/m67s04c8u9t3h6j/records "{\"Id\":1,\"Amount\":$1}" "$ETOK"; }

echo "=== T2: lifecycle on Amount col ==="
req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "{\"entity\":\"field\",\"entity_id\":\"$AC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"
PID=$($DBQ "select id from nc_permissions where entity_id='$AC' limit 1;")
echo "PID=$PID"
echo "-- step0 nobody | editor edit expect 403"; state; ed 900
echo "-- step1 -> user+[editor] expect 200 | editor edit expect 200"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$F02R4L2_EID\"}]}"; state; ed 901
echo "-- step2 -> nobody expect 200 (subjects wiped) | editor edit expect 403"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"nobody\"}"; state; ed 902
echo "-- step3 -> role+editor expect 200 | editor edit expect 200"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"role\",\"granted_role\":\"editor\"}"; state; ed 903
echo "-- step4 -> user+[editor] (role->user keep subjects path) expect 200 | editor edit expect 200"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$F02R4L2_EID\"}]}"; state; ed 904
echo "-- step5 cleanup: delete grant"
req DELETE /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID
$DBQ "select count(*) from nc_permissions where entity_id='$AC';" | xargs echo "grants left on Amount:"
