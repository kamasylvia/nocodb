#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
SC=$F02R4L2_SECRET_COL
TC=$F02R4L2_TITLE_COL
ETOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-editor@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
CTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-creator@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-commenter@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
VTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-viewer@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
req() { # method path tok body -> code
  curl -s -o /tmp/f02r4l2-last -w '%{http_code}' -X $1 "$B$2" -H "xc-auth: $3" -H 'Content-Type: application/json' ${4:+-d "$4"}
}
edit_secret() { req PATCH /api/v2/tables/m67s04c8u9t3h6j/records "$1" "{\"Id\":1,\"Secret\":\"$2\"}"; }
mkgrant() {
  $DBQ "delete from nc_permission_subjects where fk_permission_id in (select id from nc_permissions where base_id='$F02R4L2_BASE');" >/dev/null
  $DBQ "delete from nc_permissions where base_id='$F02R4L2_BASE';" >/dev/null
  case $1 in
    none) return ;;
    role) local body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"$2\"}" ;;
    user) local body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$2\"}]}" ;;
    nobody) local body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" ;;
  esac
  curl -s -o /dev/null -X POST $B/api/v2/meta/bases/$F02R4L2_BASE/permissions -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' -d "$body"
}
row() { echo "$1: editor=$(edit_secret $ETOK e) creator=$(edit_secret $CTOK c) commenter=$(edit_secret $MTOK m) viewer=$(edit_secret $VTOK v) owner=$(edit_secret $F02R4L2_TOK o)"; }

echo "=== T3: role matrix (200=edit allowed, 403=denied) ==="
mkgrant none;      row "baseline(no grant)"
mkgrant role editor;  row "role=editor   "
mkgrant role creator; row "role=creator  "
mkgrant user $F02R4L2_EID; row "user=[editor] "
mkgrant user "us_nonexistent00"; row "user=[ghost]  "
mkgrant nobody;    row "nobody        "
echo ""
echo "=== T4 tail: CUD ACL ==="
mkgrant role editor
PID=$($DBQ "select id from nc_permissions where entity_id='$SC' limit 1;")
EB="{\"entity\":\"field\",\"entity_id\":\"$TC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"
echo "editor POST:    $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions $ETOK "$EB")"
echo "editor PATCH:   $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $ETOK '{"granted_role":"creator"}')"
echo "editor DELETE:  $(req DELETE /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $ETOK)"
echo "creator PATCH valid: $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $CTOK '{"granted_role":"creator"}')"
echo "creator POST valid:  $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions $CTOK "$EB")"
P2=$($DBQ "select id from nc_permissions where entity_id='$TC' limit 1;")
echo "creator DELETE: $(req DELETE /api/v2/meta/bases/$F02R4L2_BASE/permissions/$P2 $CTOK)"
mkgrant none
echo "cleanup: grants left = $($DBQ "select count(*) from nc_permissions where base_id='$F02R4L2_BASE';")"
