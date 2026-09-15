#!/usr/bin/env zsh
# R8 lane1 F02 — D: validation symmetry, ACL, E: public form, F: regression
set -u
source /tmp/f02-lane1-env.txt
B=$BASEID; T=$TBLID; RC=$RESC
PASS=0; FAIL=0
rep() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS $1 ($3)"; else FAIL=$((FAIL+1)); echo "FAIL $1 expect=$2 got=$3"; fi }
code() { curl -s -o /tmp/f02-last.json -w "%{http_code}" "$@"; }
req() { local m=$1 u=$2 t=$3 d=${4:-}
  if [ -n "$d" ]; then code -X $m "$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d"
  else code -X $m "$u" -H "xc-auth: $t" -H 'Content-Type: application/json'; fi }
wipe() { req GET $PG $OTOK > /dev/null; for i in $(jq -r '.[].id' /tmp/f02-last.json 2>/dev/null); do req DELETE $PG/$i $OTOK > /dev/null; done }

PG=$API/api/v2/meta/bases/$B/permissions

echo "=== D. validation symmetry (owner)"
wipe
# D1 nobody + subjects
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"usX\"}]}"); rep "D1 create nobody+subjects -> 400" 400 "$r"
# D2 user without subjects
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\"}"); rep "D2 create user no-subjects -> 400" 400 "$r"
# D3 role without granted_role
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\"}"); rep "D3 create role no-role -> 400" 400 "$r"
# D4 role below minimumRole (viewer < editor min)
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}"); rep "D4 create role viewer below min -> 400" 400 "$r"
# D5 granted_role invalid enum
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"bogus\"}"); rep "D5 create role bogus enum -> 400" 400 "$r"
# D6 granted_type invalid
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"everyone\"}"); rep "D6 create bogus granted_type -> 400" 400 "$r"
# D7 table entity rejected
r=$(req POST $PG $OTOK "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"); rep "D7 create table entity -> 400" 400 "$r"
# D8 non-RECORD_FIELD_EDIT key on field
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"); rep "D8 field + wrong key -> 400" 400 "$r"
# D9 nonexistent column id
r=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"colDoesNotExist\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); rep "D9 create bad column id -> 400" 400 "$r"
# valid seed grant for update-side tests: role creator
GR=$(req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
PID=$(jq -r '.id' /tmp/f02-last.json)
# D10 update nobody+subjects
r=$(req PATCH $PG/$PID $OTOK "{\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"usX\"}]}"); rep "D10 update nobody+subjects -> 400" 400 "$r"
# D11 update user without subjects (from role type)
r=$(req PATCH $PG/$PID $OTOK "{\"granted_type\":\"user\"}"); rep "D11 update user no-subjects -> 400" 400 "$r"
# D12 update role grant granted_role null
r=$(req PATCH $PG/$PID $OTOK "{\"granted_role\":null}"); rep "D12 update role granted_role=null -> 400" 400 "$r"
# D13 update role below min
r=$(req PATCH $PG/$PID $OTOK "{\"granted_role\":\"viewer\"}"); rep "D13 update role viewer -> 400" 400 "$r"
# D14 update role bogus enum
r=$(req PATCH $PG/$PID $OTOK "{\"granted_role\":\"bogus\"}"); rep "D14 update role bogus -> 400" 400 "$r"
# D15 update bogus granted_type
r=$(req PATCH $PG/$PID $OTOK "{\"granted_type\":\"everyone\"}"); rep "D15 update bogus granted_type -> 400" 400 "$r"
# D16 update valid: role creator -> nobody (subjects retention not required)
r=$(req PATCH $PG/$PID $OTOK "{\"granted_type\":\"nobody\"}"); rep "D16 update to nobody -> 200" 200 "$r"
r=$(req GET $PG/$PID $OTOK); GT=$(jq -r '.granted_role' /tmp/f02-last.json); rep "D17 nobody grant has null granted_role" null "$GT"
# D18 nobody -> user with subjects
EID=$(echo "$ETOK" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.id')
r=$(req PATCH $PG/$PID $OTOK "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EID\"}]}"); rep "D18 nobody->user with subjects -> 200" 200 "$r"
# D19 update user grant without subjects (retains existing) -> 200
r=$(req PATCH $PG/$PID $OTOK "{\"enforce_for_form\":false}"); rep "D19 update user grant no-subjects (retain) -> 200" 200 "$r"
wipe

echo "=== D-ACL. role gates"
# editor cannot configure
r=$(req POST $PG $ETOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); rep "D20 editor POST grant -> 403" 403 "$r"
r=$(req PATCH $PG/xxx $ETOK "{\"granted_type\":\"nobody\"}"); rep "D21 editor PATCH grant -> 403" 403 "$r"
r=$(req DELETE $PG/xxx $ETOK); rep "D22 editor DELETE grant -> 403" 403 "$r"
# editor CAN read (R2: editors+ visibility)
r=$(req GET $PG $ETOK); rep "D23 editor GET grants -> 200" 200 "$r"

echo "=== E. public form enforce_for_form"
# create form view (correct endpoint: /meta/tables/:id/forms)
FV=$(req POST $API/api/v2/meta/tables/$T/forms $OTOK '{"title":"r8l1form"}')
rep "E1 create form view" 200 "$FV"
VID=$(jq -r '.id' /tmp/f02-last.json)
SH=$(req POST $API/api/v2/meta/views/$VID/share $OTOK)
UUID=$(jq -r '.uuid' /tmp/f02-last.json)
echo "form uuid=$UUID"
SUB=$API/api/v2/public/shared-view/$UUID/rows
# baseline: anonymous submit w/o grants
r=$(code -X POST $SUB -H 'Content-Type: application/json' -d '{"data":{"Title":"anon0","Restricted":"a0"}}'); rep "E2 anon submit no-grants -> 200" 200 "$r"
# grant nobody (enforce_for_form default true) -> 403
req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" > /dev/null
GRANT_ID=$(jq -r '.id' /tmp/f02-last.json)
r=$(code -X POST $SUB -H 'Content-Type: application/json' -d '{"data":{"Title":"anon1","Restricted":"a1"}}'); rep "E3 anon submit nobody(default enforce) -> 403" 403 "$r"
# flip enforce_for_form=false -> allowed
r=$(req PATCH $PG/$GRANT_ID $OTOK '{"enforce_for_form":false}'); rep "E4 PATCH enforce_for_form=false -> 200" 200 "$r"
r=$(code -X POST $SUB -H 'Content-Type: application/json' -d '{"data":{"Title":"anon2","Restricted":"a2"}}'); rep "E5 anon submit enforce=false -> 200" 200 "$r"
# user-grant + anonymous (SDK hard-deny even with enforce=false? tableFieldPermission anon rule) — nobody grant deleted, user grant
req DELETE $PG/$GRANT_ID $OTOK > /dev/null
EID=$(echo "$ETOK" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.id')
req POST $PG $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EID\"}],\"enforce_for_form\":false}" > /dev/null
GRANT_ID=$(jq -r '.id' /tmp/f02-last.json)
r=$(code -X POST $SUB -H 'Content-Type: application/json' -d '{"data":{"Title":"anon3","Restricted":"a3"}}'); rep "E6 anon submit user-grant enforce=false -> 403 (anon not in subjects)" 403 "$r"
req DELETE $PG/$GRANT_ID $OTOK > /dev/null
r=$(code -X POST $SUB -H 'Content-Type: application/json' -d '{"data":{"Title":"anon4","Restricted":"a4"}}'); rep "E7 anon submit after delete -> 200 (fail-open)" 200 "$r"

echo "=== F. regression F05/F07/F08/F10"
r=$(req GET $API/api/v2/meta/bases/$B/variables $OTOK); rep "F1 F05 GET variables -> 200" 200 "$r"
r=$(req GET $API/api/v2/meta/bases/$B/snapshots $OTOK); rep "F2 F07 GET snapshots -> 200" 200 "$r"
r=$(req GET $API/api/v2/meta/bases/$B $OTOK); rep "F3 F08 GET base meta -> 200" 200 "$r"
r=$(req GET $API/api/v2/meta/bases/$B/dashboards $OTOK); rep "F4 F10 GET dashboards -> 200" 200 "$r"
# data write still fine for owner after all F02 hooks (no grants)
r=$(req PATCH $API/api/v2/tables/$T/records $OTOK '{"Id":1,"Normal":"regr"}'); rep "F5 owner data write -> 200" 200 "$r"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL"
