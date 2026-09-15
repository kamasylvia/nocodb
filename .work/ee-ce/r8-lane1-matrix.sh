#!/usr/bin/env zsh
# R8 lane1 F02 — A: R7 fix verify, B: full matrix, C: fail-open
set -u
source /tmp/f02-lane1-env.txt
B=$BASEID; T=$TBLID; RC=$RESC
PASS=0; FAIL=0

# helper: report name expected got
rep() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS $1 ($3)"; else FAIL=$((FAIL+1)); echo "FAIL $1 expect=$2 got=$3"; fi }

code() { curl -s -o /tmp/f02-last.json -w "%{http_code}" "$@"; }

req() { # method url tok [data]
  local m=$1 u=$2 t=$3 d=${4:-}
  if [ -n "$d" ]; then code -X $m "$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d"
  else code -X $m "$u" -H "xc-auth: $t" -H 'Content-Type: application/json'; fi
}

wipe_grants() {
  req GET $PGAPI $OTOK > /dev/null
  for ids in $(jq -r '.[].id' /tmp/f02-last.json 2>/dev/null); do req DELETE $PGAPI/$ids $OTOK > /dev/null; done
}

V2=$API/api/v2/tables/$T/records
V1D=$API/api/v1/db/data/noco/$B/$T
BULK=$API/api/v1/db/data/bulk/noco/$B/$T
PGAPI=$API/api/v2/meta/bases/$B/permissions

echo "=== A. R7 fix verify: nobody grant lifecycle"
GA=$(req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
rep "A1 POST nobody grant" 200 "$GA"
GRANT_ID=$(jq -r ".id" /tmp/f02-last.json)
GA2=$(req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")
rep "A2 POST duplicate same-key grant -> 400" 400 "$GA2"
GA3=$(req PATCH $PGAPI/$GRANT_ID $OTOK "{\"granted_type\":\"nobody\"}")
rep "A3 PATCH same grant to nobody (R7 Save path) -> 200" 200 "$GA3"
echo "--- fail-open: delete grant then editor PATCH Restricted"
GD=$(req DELETE $PGAPI/$GRANT_ID $OTOK)
SEED=$(req POST $V2 $OTOK '{"Title":"seed1","Normal":"n1"}')
RID=$(jq -r '.Id' /tmp/f02-last.json)
GE=$(req PATCH $V2 $ETOK "{\"Id\":$RID,\"Restricted\":\"e-after-delete\"}")
rep "A4 grant deleted -> editor PATCH Restricted -> 200 (fail-open)" 200 "$GE"

echo "=== B. matrix (grants x users x paths)"
# B-paths runner: args grant_desc tok expected
run_paths() {
  local gdesc=$1 tok=$2 exp=$3
  local r
  # p1 PATCH v2 single (Restricted)
  r=$(req PATCH $V2 $tok "{\"Id\":$RID,\"Restricted\":\"chg\"}"); rep "B[$gdesc] PATCH v2 Restricted" "$exp" "$r"
  # p1n PATCH v2 Normal-only (always 200)
  r=$(req PATCH $V2 $tok "{\"Id\":$RID,\"Normal\":\"nn\"}"); rep "B[$gdesc] PATCH v2 Normal-only" 200 "$r"
  # p3 insert v2 with Restricted
  r=$(req POST $V2 $tok '{"Title":"i","Restricted":"v"}'); rep "B[$gdesc] INSERT v2 Restricted" "$exp" "$r"
  # p4 bulkInsert v2 array
  r=$(req POST $V2 $tok '[{"Title":"bi","Restricted":"v"}]'); rep "B[$gdesc] bulkInsert v2 Restricted" "$exp" "$r"
  # p5 bulkUpdate v2 array
  r=$(req PATCH $V2 $tok "[{\"Id\":$RID,\"Restricted\":\"bu\"}]"); rep "B[$gdesc] bulkUpdate v2 Restricted" "$exp" "$r"
  # p6 bulkUpdateAll v1 .../all
  r=$(req PATCH "$BULK/all" $tok '{"Restricted":"bua"}'); rep "B[$gdesc] bulkUpdateAll v1" "$exp" "$r"
  # p7 bulkUpsert v1
  r=$(req POST "$BULK/upsert" $tok "[{\"Id\":$RID,\"Restricted\":\"up\"}]"); rep "B[$gdesc] bulkUpsert v1" "$exp" "$r"
  # p8 v1 insert with Restricted (title key)
  r=$(req POST $V1D $tok '{"Title":"v1i","Restricted":"v1"}'); rep "B[$gdesc] INSERT v1 Restricted" "$exp" "$r"
  # p9 v1 updateByPk
  r=$(req PATCH $V1D/$RID $tok '{"Restricted":"v1u"}'); rep "B[$gdesc] PATCH v1 (updateByPk) Restricted" "$exp" "$r"
}

echo "--- G1 nobody (recreate)"
req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}" > /dev/null
run_paths "G1nobody" "$ETOK" 403
run_paths "G1nobody" "$CTOK" 403
# owner only PATCH+insert spot checks (owner always passes)
r=$(req PATCH $V2 $OTOK "{\"Id\":$RID,\"Restricted\":\"ow\"}"); rep "B[G1nobody] owner PATCH" 200 "$r"
r=$(req POST $V2 $OTOK '{"Title":"oi","Restricted":"ow"}'); rep "B[G1nobody] owner INSERT" 200 "$r"

echo "--- G2 role:editor"
wipe_grants
GRANT_ID=$(req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
GRANT_ID=$(jq -r ".id" /tmp/f02-last.json)
run_paths "G2role-editor" "$ETOK" 200
run_paths "G2role-editor" "$CTOK" 200
req DELETE $PGAPI/$GRANT_ID $OTOK > /dev/null

echo "--- G3 role:creator"
wipe_grants
req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}" > /dev/null
run_paths "G3role-creator" "$ETOK" 403
run_paths "G3role-creator" "$CTOK" 200
# cleanup by listing and deleting
wipe_grants

echo "--- G4 user:[editorId]"
EID=$(echo "$ETOK" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.id')
echo "editor userId=$EID"
req POST $PGAPI $OTOK "{\"entity\":\"field\",\"entity_id\":\"$RC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EID\"}]}" > /dev/null
run_paths "G4user-editor" "$ETOK" 200
run_paths "G4user-editor" "$CTOK" 403
wipe_grants

echo "=== C. fail-open final check (all grants removed)"
wipe_grants
r=$(req PATCH $V2 $ETOK "{\"Id\":$RID,\"Restricted\":\"free\"}"); rep "C1 no grants -> editor PATCH 200" 200 "$r"
req GET $PGAPI $OTOK > /dev/null; N=$(jq 'length' /tmp/f02-last.json 2>/dev/null); rep "C2 grants list empty" 0 "$N"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL"
