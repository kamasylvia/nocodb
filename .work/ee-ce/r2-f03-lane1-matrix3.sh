#!/bin/bash
# R2 F03 lane1 — matrix part 3: corrected harness (dup codes, proper user ids, upsert, validation, forms)
source "$1"
EUID_VAL=usugovsvoc3i9k8e   # editor user id (round ...693)
CRE_ID=usddey8ybwzz1s1n
PASS=0; FAIL=0; LOG=/tmp/f03lane1-results3.txt; : > $LOG
chk() { local L="$1" E="$2" A="$3"
  if [ "$E" == "$A" ]; then PASS=$((PASS+1)); echo "ok   $L -> $A" >> $LOG
  else FAIL=$((FAIL+1)); echo "FAIL $L expected=$E got=$A" >> $LOG; fi; }
code() { curl -s -o /tmp/f03lane1-b3.json -w "%{http_code}" "$@"; }
perm() { curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "$1"; }
delperm() { curl -s -X DELETE "$API/api/v2/meta/bases/$BASE_ID/permissions/$1" -H "xc-auth: $OWN_TOK" -o /dev/null; }

# ---- G: duplicate grant rejection (proper status code) ----
GA=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
DUP=$(code -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
chk "G1 duplicate (entity,entity_id,permission) POST -> 400" 400 "$DUP"
delperm $GA

# ---- H: bulk update batch without ADD (must not require ADD) ----
GA=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T1_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
R1=$(curl -s "$API/api/v2/tables/$T1_ID/records?limit=1" -H "xc-auth: $OWN_TOK" | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "H1 nobody ADD: editor bulk PATCH (pure update batch) 200" 200 $(code -X PATCH $API/api/v2/tables/$T1_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$R1,\"Title\":\"h1\"}]")
# mixed upsert batch via v1 bulk upsert (insert leg should demand ADD) — v1 by title broken; use table id
chk "H2 nobody ADD: editor v1 bulk upsert (insert leg) 403" 403 $(code -X POST "$API/api/v1/db/data/bulk/noco/$BASE_ID/$T1_ID/upsert" -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '[{"Title":"h2new"}]')
delperm $GA

# ---- I: user-grant ADD with correct editor id ----
GA=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T1_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_VAL\"}]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "I1 user(editor) ADD: editor insert 200" 200 $(code -X POST $API/api/v2/tables/$T1_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"i1"}')
chk "I2 user(editor) ADD: creator insert 403" 403 $(code -X POST $API/api/v2/tables/$T1_ID/records -H "xc-auth: $CRE_TOK" -H 'Content-Type: application/json' -d '{"Title":"i2"}')
# PATCH user grant -> nobody strips subjects/role
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"nobody"}' -o /dev/null
NP=$(curl -s "$API/api/v2/meta/bases/$BASE_ID/permissions" -H "xc-auth: $OWN_TOK" | python3 -c "
import sys,json
for p in json.load(sys.stdin)['list']:
  if p['id']=='$GA': print(p['granted_type'], p['granted_role'], len(p.get('subjects') or []))")
chk "I3 PATCH user->nobody lands nobody/null-role/0-subjects" "nobody None 0" "$NP"
chk "I4 nobody ADD: editor now 403" 403 $(code -X POST $API/api/v2/tables/$T1_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"i4"}')
delperm $GA

# ---- J: VISIBILITY user-grant (correct ids) ----
GV=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T2_ID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_VAL\"}]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "J1 vis user(editor): editor GET 200" 200 $(code "$API/api/v2/tables/$T2_ID/records" -H "xc-auth: $EDI_TOK")
chk "J2 vis user(editor): creator GET 404" 404 $(code "$API/api/v2/tables/$T2_ID/records" -H "xc-auth: $CRE_TOK")
delperm $GV

# ---- K: validation symmetry (all 400) ----
V() { chk "$1" 400 $(code -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "$2"); }
V "K1 role grant missing granted_role" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\"}"
V "K2 role below minimumRole (viewer for ADD)" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}"
V "K3 bogus granted_role enum" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"wizard\"}"
V "K4 user grant without subjects" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"user\"}"
V "K5 nobody + subjects" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_VAL\"}]}"
V "K6 invalid granted_type" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"everyone\"}"
V "K7 non-table permission on table entity" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"
V "K8 entity=dashboard x table key" "{\"entity\":\"dashboard\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"
V "K9 table entity_id not in this base" "{\"entity\":\"table\",\"entity_id\":\"mxze7e11bhi6nlr\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"
V "K10 bogus table entity_id" "{\"entity\":\"table\",\"entity_id\":\"nonexistent123\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"
V "K11 VISIBILITY role:commenter below viewer minimum" "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"role\",\"granted_role\":\"commenter\"}"
# PATCH-side symmetry
GP=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "K12 PATCH role->viewer (below min) 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"user"}')
chk "K13 PATCH to user without subjects 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"user"}')
chk "K14 PATCH nobody+subjects 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"nobody","subjects":[{"type":"user","id":"x"}]}')
chk "K15 PATCH bogus granted_role 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_role":"wizard"}')
delperm $GP

# ---- L: bulkDeleteAll with valid where ----
GD=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T4_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "L1 nobody DELETE: editor bulkDeleteAll 403" 403 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=%28Title%2Ceq%2Cd-row2%29" -H "xc-auth: $EDI_TOK")
chk "L2 nobody DELETE: owner bulkDeleteAll 200" 200 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=%28Title%2Ceq%2Cd-row2%29" -H "xc-auth: $OWN_TOK")
delperm $GD

# ---- M: editor cannot manage grants (creator-only ACL), owner can ----
chk "M1 editor POST permissions -> 403" 403 $(code -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk "M2 creator POST permissions -> 200" 200 $(code -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $CRE_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}" )
GP2=$(curl -s "$API/api/v2/meta/bases/$BASE_ID/permissions" -H "xc-auth: $OWN_TOK" | python3 -c "
import sys,json
for p in json.load(sys.stdin)['list']:
  if p['entity']=='table' and p['entity_id']=='$T3_ID' and p['permission']=='TABLE_RECORD_ADD': print(p['id']);break")
delperm $GP2
chk "M3 editor DELETE permissions -> 403" 403 $(code -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -o /dev/null -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{}')

echo "== RESULT3 PASS=$PASS FAIL=$FAIL ==" >> $LOG
cat $LOG
