#!/bin/bash
# F02 R2 lane1 — integration tests v2 (fixed GID/ROW resolution, correct routes)
set -u
source /tmp/f02r2l1-state.sh
PSQL="/opt/homebrew/opt/libpq@18/bin/psql"
PG="postgresql://postgres:postgres@qnap.elf-balance.ts.net:5432/nocodb-dev"
# resolve the single nobody grant + a seeded row fresh every run
GID=$($PSQL "$PG" -tAc "SELECT id FROM nc_permissions WHERE base_id='$BID' AND entity_id='$COL_SECRET' LIMIT 1" | tr -d '[:space:]')
ROW=$(api=1; curl -s -m 30 -X POST "$B/api/v2/tables/$TID/records" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Title":"seedrow","Secret":"s0"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['Id'])")
PASS=0; FAIL=0; RESULTS=""

api(){ local m=$1 p=$2 t=$3 d=${4:-}; if [ -n "$d" ]; then curl -s -m 60 -X "$m" "$B$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d"; else curl -s -m 60 -X "$m" "$B$p" -H "xc-auth: $t"; fi; }
code(){ local m=$1 p=$2 t=$3 d=${4:-}; if [ -n "$d" ]; then curl -s -m 60 -o /tmp/r.json -w '%{http_code}' -X "$m" "$B$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d"; else curl -s -m 60 -o /tmp/r.json -w '%{http_code}' -X "$m" "$B$p" -H "xc-auth: $t"; fi; }
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS
PASS $1"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS
FAIL $1 (expect $2 got $3) $(head -c 160 /tmp/r.json 2>/dev/null)"; fi; }
setgrant(){ curl -s -m 30 -X PATCH "$B/api/v2/meta/bases/$BID/permissions/$GID" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "$1" -o /dev/null; }

echo "GID=$GID ROW=$ROW"

################ T-A: R1 nestedInsert v1 route
setgrant '{"granted_type":"nobody"}'
chk "A1 v1-route editor insert w/ Secret => 403" 403 "$(code POST /api/v1/db/data/noco/$BID/$TID "$ET" '{"Title":"v1a","Secret":"v"}')"
chk "A2 v1-route editor insert w/o Secret => 200" 200 "$(code POST /api/v1/db/data/noco/$BID/$TID "$ET" '{"Title":"v1b"}')"
chk "A3 v2 editor insert w/ Secret => 403" 403 "$(code POST /api/v2/tables/$TID/records "$ET" '{"Title":"a3","Secret":"v"}')"

################ T-B: duplicate grant => 400
chk "B1 duplicate grant POST v2 => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_SECRET\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")"
chk "B2 duplicate grant POST v1 => 400" 400 "$(code POST /api/v1/db/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_SECRET\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")"

################ T-C: role/user/nobody matrix
setgrant '{"granted_type":"role","granted_role":"creator"}'
chk "C1 editor insert w/ Secret (role=creator) => 403" 403 "$(code POST /api/v2/tables/$TID/records "$ET" '{"Title":"c1","Secret":"x"}')"
chk "C2 creator insert w/ Secret (role=creator) => 200" 200 "$(code POST /api/v2/tables/$TID/records "$CT" '{"Title":"c2","Secret":"x"}')"
setgrant '{"granted_type":"role","granted_role":"editor"}'
chk "C3 editor insert w/ Secret (role=editor) => 200" 200 "$(code POST /api/v2/tables/$TID/records "$ET" '{"Title":"c3","Secret":"x"}')"
chk "C4 editor PATCH row Secret (role=editor) => 200" 200 "$(code PATCH /api/v2/tables/$TID/records "$ET" "[{\"Id\":$ROW,\"Secret\":\"s2\"}]")"
setgrant "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$CID\"}]}"
chk "C5 editor PATCH Secret (user grant, not subject) => 403" 403 "$(code PATCH /api/v2/tables/$TID/records "$ET" "[{\"Id\":$ROW,\"Secret\":\"s3\"}]")"
chk "C6 creator PATCH Secret (user grant, subject) => 200" 200 "$(code PATCH /api/v2/tables/$TID/records "$CT" "[{\"Id\":$ROW,\"Secret\":\"s4\"}]")"
setgrant '{"granted_type":"nobody"}'
chk "C7 owner PATCH Secret (nobody) => 200" 200 "$(code PATCH /api/v2/tables/$TID/records "$OT" "[{\"Id\":$ROW,\"Secret\":\"s5\"}]")"
chk "C8 editor single-row v1 update Secret (nobody) => 403" 403 "$(code PATCH /api/v1/db/data/noco/$BID/$TID/$ROW "$ET" '{"Secret":"sx"}')"

################ T-D: user-grant subject validation on update
chk "D1 PATCH -> user grant w/o subjects => 400" 400 "$(code PATCH /api/v2/meta/bases/$BID/permissions/$GID "$OT" '{"granted_type":"user"}')"

################ T-E: nobody dirty-state + granted_role validation on PATCH
GR=$($PSQL "$PG" -tAc "SELECT granted_role FROM nc_permissions WHERE id='$GID'" | tr -d '[:space:]')
chk "E1 nobody cleared granted_role (empty)" "" "$GR"
chk "E2 PATCH -> role viewer (below minimumRole) => 400" 400 "$(code PATCH /api/v2/meta/bases/$BID/permissions/$GID "$OT" '{"granted_type":"role","granted_role":"viewer"}')"
chk "E3 PATCH -> role bogus => 400" 400 "$(code PATCH /api/v2/meta/bases/$BID/permissions/$GID "$OT" '{"granted_type":"role","granted_role":"NotARole"}')"
# nobody -> back to user without subjects (legacy subjects were empty) => 400
chk "E4 nobody -> user w/o subjects => 400" 400 "$(code PATCH /api/v2/meta/bases/$BID/permissions/$GID "$OT" '{"granted_type":"user"}')"

################ T-F: multi-grant any-deny (legacy duplicate row via psql)
$PSQL "$PG" -tAc "INSERT INTO nc_permissions (id, fk_workspace_id, base_id, entity, entity_id, permission, created_by, enforce_for_form, enforce_for_automation, granted_type, granted_role, created_at, updated_at) SELECT 'permlane1dup1', fk_workspace_id, base_id, entity, entity_id, permission, created_by, true, true, 'role', 'editor', now(), now() FROM nc_permissions WHERE id='$GID'" >/dev/null
chk "F1 legacy dup (nobody+role-editor): editor blocked => 403" 403 "$(code PATCH /api/v2/tables/$TID/records "$ET" "[{\"Id\":$ROW,\"Secret\":\"s6\"}]")"
$PSQL "$PG" -tAc "DELETE FROM nc_permissions WHERE id='permlane1dup1'" >/dev/null

################ T-G: bulk paths (grant role=creator)
setgrant '{"granted_type":"role","granted_role":"creator"}'
chk "G1 editor bulkInsert v2 w/ Secret => 403" 403 "$(code POST /api/v2/tables/$TID/records "$ET" '[{"Title":"b1","Secret":"x"}]')"
chk "G2 editor bulkInsert v2 w/o Secret => 200" 200 "$(code POST /api/v2/tables/$TID/records "$ET" '[{"Title":"b2"}]')"
chk "G3 editor bulkUpdate v1 w/ Secret => 403" 403 "$(code PATCH /api/v1/db/data/bulk/noco/$BID/$TID "$ET" "[{\"Id\":$ROW,\"Secret\":\"x\"}]")"
chk "G4 editor bulkUpdateAll v1 w/ Secret => 403" 403 "$(code PATCH /api/v1/db/data/bulk/noco/$BID/$TID/all "$ET" '{"Secret":"x"}')"
chk "G5 editor bulkUpsert v1 w/ Secret => 403" 403 "$(code POST /api/v1/db/data/bulk/noco/$BID/$TID/upsert "$ET" '[{"Title":"u1","Secret":"x"}]')"

################ T-H: cache immediacy
api DELETE /api/v2/meta/bases/$BID/permissions/$GID "$OT" >/dev/null
chk "H1 delete grant -> editor insert w/ Secret immediately 200" 200 "$(code POST /api/v2/tables/$TID/records "$ET" '{"Title":"h1","Secret":"x"}')"
R=$(api POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_SECRET\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
GID=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "H2 create nobody grant -> editor insert immediately 403" 403 "$(code POST /api/v2/tables/$TID/records "$ET" '{"Title":"h2","Secret":"x"}')"

################ T-I: public form (anonymous)
chk "I1 anon form submit w/ Secret (enforce=true) => 403" 403 "$(code POST /api/v2/public/shared-view/$UUID/rows '' '{"data":{"Title":"anon1","Secret":"a"}}')"
chk "I2 anon form submit w/o Secret => 200" 200 "$(code POST /api/v2/public/shared-view/$UUID/rows '' '{"data":{"Title":"anon2"}}')"
setgrant '{"granted_type":"nobody","enforce_for_form":false}'
chk "I3 anon form submit w/ Secret (enforce=false) => 200" 200 "$(code POST /api/v2/public/shared-view/$UUID/rows '' '{"data":{"Title":"anon3","Secret":"a"}}')"
setgrant '{"granted_type":"nobody","enforce_for_form":true}'
# role-grant + anonymous form (enforce=true) => 403
setgrant '{"granted_type":"role","granted_role":"editor","enforce_for_form":true}'
chk "I4 anon form w/ Secret (role-editor enforce=true) => 403" 403 "$(code POST /api/v2/public/shared-view/$UUID/rows '' '{"data":{"Title":"anon4","Secret":"a"}}')"
setgrant '{"granted_type":"nobody"}'

################ T-J: fail-open on T2 (no grants) — editor full CRUD
chk "J1 T2 editor insert => 200" 200 "$(code POST /api/v2/tables/$T2/records "$ET" '{"Title":"t2a"}')"
R2=$(api POST /api/v2/tables/$T2/records "$OT" '{"Title":"t2seed"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['Id'])")
chk "J2 T2 editor update => 200" 200 "$(code PATCH /api/v2/tables/$T2/records "$ET" "[{\"Id\":$R2,\"Title\":\"t2b\"}]")"
chk "J3 T2 editor delete => 200" 200 "$(code DELETE /api/v2/tables/$T2/records/$R2 "$ET")"

################ T-K: skip channel — snapshot create/restore with restricted field
chk "K1 create snapshot => 200" 200 "$(code POST /api/v2/meta/bases/$BID/snapshots "$OT" '{}')"

################ T-L: ACL — editor denied, creator allowed on permission CRUD
chk "L1 editor GET permissions => 403" 403 "$(code GET /api/v2/meta/bases/$BID/permissions "$ET")"
chk "L2 editor POST permission => 403" 403 "$(code POST /api/v2/meta/bases/$BID/permissions "$ET" "{\"entity\":\"field\",\"entity_id\":\"$COL_TITLE\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")"
chk "L3 creator GET permissions => 200" 200 "$(code GET /api/v2/meta/bases/$BID/permissions "$CT")"
chk "L4 creator POST permission => 200" 200 "$(code POST /api/v2/meta/bases/$BID/permissions "$CT" "{\"entity\":\"field\",\"entity_id\":\"$COL_TITLE\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")"
GID2=$($PSQL "$PG" -tAc "SELECT id FROM nc_permissions WHERE base_id='$BID' AND entity_id='$COL_TITLE' LIMIT 1" | tr -d '[:space:]')
api DELETE /api/v2/meta/bases/$BID/permissions/$GID2 "$CT" >/dev/null

################ T-M: validation errors
chk "M1 entity=table rejected => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")"
chk "M2 bogus permission key => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_SECRET\",\"permission\":\"BOGUS_KEY\",\"granted_type\":\"nobody\"}")"
chk "M3 bogus column => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" '{"entity":"field","entity_id":"nonexistentcol99","permission":"RECORD_FIELD_EDIT","granted_type":"nobody"}')"
chk "M4 team subject rejected => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_TITLE\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"team\",\"id\":\"t1\"}]}")"
chk "M5 role grant below minimumRole (viewer) => 400" 400 "$(code POST /api/v2/meta/bases/$BID/permissions "$OT" "{\"entity\":\"field\",\"entity_id\":\"$COL_TITLE\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")"
chk "M6 unknown permissionId PATCH => 404" 404 "$(code PATCH /api/v2/meta/bases/$BID/permissions/nonexistent123 "$OT" '{"granted_type":"nobody"}')"

################ T-O: regression — F05/F07/F10/F08 + permission list
chk "O1 F05 variables list => 200" 200 "$(code GET /api/v2/meta/bases/$BID/variables "$OT")"
chk "O2 F07 snapshots list => 200" 200 "$(code GET /api/v2/meta/bases/$BID/snapshots "$OT")"
chk "O3 F10 dashboards list => 200" 200 "$(code GET /api/v2/meta/bases/$BID/dashboards "$OT")"
PRIV=$(api GET /api/v2/meta/bases/$BID "$OT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('is_private'))")
chk "O4 F08 base is_private=false" "False" "$PRIV"
chk "O5 permissions list => 200" 200 "$(code GET /api/v2/meta/bases/$BID/permissions "$OT")"

echo "$RESULTS"
echo "== PASS=$PASS FAIL=$FAIL =="
