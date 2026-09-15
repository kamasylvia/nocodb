#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
SC=$F02R4L2_SECRET_COL
TC=$F02R4L2_TITLE_COL
ETOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-editor@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
req() { curl -s -o /tmp/f02r4l2-last -w '%{http_code}' -X $1 "$B$2" -H "xc-auth: ${3:-$F02R4L2_TOK}" -H 'Content-Type: application/json' ${4:+-d "$4"}; }
mkrole() { $DBQ "delete from nc_permission_subjects where fk_permission_id in (select id from nc_permissions where base_id='$F02R4L2_BASE');" >/dev/null; $DBQ "delete from nc_permissions where base_id='$F02R4L2_BASE';" >/dev/null; curl -s -o /dev/null -X POST $B/api/v2/meta/bases/$F02R4L2_BASE/permissions -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}"; $DBQ "select id from nc_permissions where entity_id='$SC' limit 1;"; }
st() { $DBQ "select granted_type||'|'||coalesce(granted_role,'<NULL>') from nc_permissions where id='$1';"; }

echo "=== T6a: role row PATCH granted_role:null ==="
PID=$(mkrole); echo "start: $(st $PID)"
echo "PATCH {granted_role:null} -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"granted_role":null}')"
echo "state: $(st $PID)"
echo "editor edit now: $(req PATCH /api/v2/tables/m67s04c8u9t3h6j/records $ETOK '{"Id":1,"Secret":"t6a"}') (null-role should deny editor)"

echo ""
echo "=== T6b: role row PATCH granted_role:\"\" ==="
PID=$(mkrole); echo "start: $(st $PID)"
echo "PATCH {granted_role:\"\"} -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"granted_role":""}')"
echo "state: $(st $PID)"

echo ""
echo "=== T6c: user row PATCH team subject (create rejects team; update path?) ==="
$DBQ "delete from nc_permissions where base_id='$F02R4L2_BASE';" >/dev/null
curl -s -o /dev/null -X POST $B/api/v2/meta/bases/$F02R4L2_BASE/permissions -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$F02R4L2_EID\"}]}"
PID=$($DBQ "select id from nc_permissions where entity_id='$SC' limit 1;")
echo "PATCH {subjects:[team]} (no granted_type) -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"subjects":[{"type":"team","id":"team_x"}]}')"
echo "subjects now: $($DBQ "select subject_type||':'||subject_id from nc_permission_subjects where fk_permission_id='$PID';" | tr '\n' ' ')"

echo ""
echo "=== T6d/e/f/g/h: edges ==="
echo "user row PATCH {granted_type:user, subjects:[]} -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"granted_type":"user","subjects":[]}')"
echo "PATCH subjects missing id -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"subjects":[{"type":"user"}]}')"
echo "PATCH enforce_for_form:false -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"enforce_for_form":false}')  enforce=$($DBQ "select enforce_for_form from nc_permissions where id='$PID';")"
echo "PATCH unknown id -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/permnonexistent00 $F02R4L2_TOK '{"granted_type":"nobody"}')"
echo "PATCH {entity:table} immutability -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $F02R4L2_TOK '{"entity":"table"}')  entity=$($DBQ "select entity from nc_permissions where id='$PID';")"
$DBQ "delete from nc_permissions where base_id='$F02R4L2_BASE';" >/dev/null; $DBQ "delete from nc_permission_subjects;" >/dev/null
