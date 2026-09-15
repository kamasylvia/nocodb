#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
SC=$F02R4L2_SECRET_COL
ETOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-editor@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
CTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-creator@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-commenter@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
VTOK=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f02r4l2-viewer@test.local","password":"F02r4l2!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
code() { curl -s -o /dev/null -w '%{http_code}' -X $1 "$B$2" -H "xc-auth: $3" -H 'Content-Type: application/json' ${4:+-d "$4"}; }
edit_secret() { code PATCH /api/v2/tables/m67s04c8u9t3h6j/records "{\"Id\":1,\"Secret\":\"x-$1\"}" "$2"; }
mkgrant() { # type role? -> creates fresh grant on Secret, returns PID
  $DBQ "delete from nc_permission_subjects where fk_permission_id in (select id from nc_permissions where entity_id='$SC');" >/dev/null
  $DBQ "delete from nc_permissions where entity_id='$SC';" >/dev/null
  local body
  case $1 in
    none) echo "" ; return ;;
    role) body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"$2\"}" ;;
    user) body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$2\"}]}" ;;
    nobody) body="{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" ;;
  esac
  curl -s -X POST $B/api/v2/meta/bases/$F02R4L2_BASE/permissions -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' -d "$body" >/dev/null
}

echo "=== T3: role matrix ==="
echo "baseline(no grant): editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant role editor
echo "role=editor:        editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant role creator
echo "role=creator:       editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant user $F02R4L2_EID
echo "user=[editor]:      editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant user "us_nonexistent00"
echo "user=[nonexistent]: editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant nobody
echo "nobody:             editor=$(edit_secret e $ETOK) creator=$(edit_secret c $CTOK) commenter=$(edit_secret m $MTOK) viewer=$(edit_secret v $VTOK) owner=$(edit_secret o $F02R4L2_TOK)"
mkgrant none
echo "cleanup done"

echo ""
echo "=== T4: permissionList ACL ==="
# recreate a grant for list tests
mkgrant role editor
echo "GET list:    owner=$(code GET /api/v2/meta/bases/$F02R4L2_BASE/permissions $F02R4L2_TOK) creator=$(code GET /api/v2/meta/bases/$F02R4L2_BASE/permissions $CTOK) editor=$(code GET /api/v2/meta/bases/$F02R4L2_BASE/permissions $ETOK) commenter=$(code GET /api/v2/meta/bases/$F02R4L2_BASE/permissions $MTOK) viewer=$(code GET /api/v2/meta/bases/$F02R4L2_BASE/permissions $VTOK)"
# cross-base isolation: pick a foreign base id
FB=$($DBQ "select id from nc_bases_v2 where id <> '$F02R4L2_BASE' and deleted is not true limit 1;")
echo "cross-base editor GET foreign base ($FB): $(code GET /api/v2/meta/bases/$FB/permissions $ETOK)"
# CUD by editor should be 403
echo "editor POST: $(code POST /api/v2/meta/bases/$F02R4L2_BASE/permissions $ETOK "{\"entity\":\"field\",\"entity_id\":\"$F02R4L2_TITLE_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\""}")"
PID=$($DBQ "select id from nc_permissions where entity_id='$SC' limit 1;")
echo "editor PATCH: $(code PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $ETOK '{"granted_role":"creator"}')"
echo "editor DELETE: $(code DELETE /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $ETOK)"
echo "creator PATCH (valid): $(code PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $CTOK '{"granted_role":"creator"}')"
echo "creator DELETE: $(code DELETE /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID $CTOK)"
