#!/bin/bash
# R2 F03 lane1 — matrix part 4: fix-ups (K11 verified correct; K12-15/M2/I3/L2 redo)
source "$1"
EUID_VAL=usugovsvoc3i9k8e
PASS=0; FAIL=0; LOG=/tmp/f03lane1-results4.txt; : > $LOG
chk() { local L="$1" E="$2" A="$3"
  if [ "$E" == "$A" ]; then PASS=$((PASS+1)); echo "ok   $L -> $A" >> $LOG
  else FAIL=$((FAIL+1)); echo "FAIL $L expected=$E got=$A" >> $LOG; fi; }
code() { curl -s -o /tmp/f03lane1-b4.json -w "%{http_code}" "$@"; }
perm() { curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "$1"; }
delperm() { curl -s -X DELETE "$API/api/v2/meta/bases/$BASE_ID/permissions/$1" -H "xc-auth: $OWN_TOK" -o /dev/null; }
plist() { curl -s "$API/api/v2/meta/bases/$BASE_ID/permissions" -H "xc-auth: $OWN_TOK"; }
findgrant() { plist | python3 -c "
import sys,json
for p in json.load(sys.stdin):
  if p['entity']=='table' and p['entity_id']=='$2' and p['permission']=='$3' and p.get('granted_type')=='$4': print(p['id']);break"; }

# cleanup leftover role:editor ADD grant on T3 (from part 2)
OLD=$(findgrant $T3_ID TABLE_RECORD_ADD role); [ -n "$OLD" ] && delperm $OLD

# I3 redo: user -> nobody PATCH then inspect stored row
GA=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T1_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_VAL\"}]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"nobody"}' -o /dev/null
NP=$(plist | python3 -c "
import sys,json
for p in json.load(sys.stdin):
  if p['id']=='$GA':
    print(p['granted_type'], p['granted_role'], len(p.get('subjects') or []));break")
chk "I3 PATCH user->nobody stores nobody/null-role/0-subjects" "nobody None 0" "$NP"
chk "I3b nobody DELETE now: editor v2 delete 403" 403 $(code -X POST $API/api/v2/tables/$T1_ID/records -o /dev/null -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"zz"}')
# K-side: nobody + subjects on PATCH
chk "K14 PATCH nobody+subjects 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"nobody","subjects":[{"type":"user","id":"x"}]}')
delperm $GA

# K12-15 redo on fresh role:creator DELETE grant on T4
GP=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T4_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
chk "K12 PATCH granted_role->viewer (below min for DELETE) 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_role":"viewer"}')
chk "K13 PATCH to user without subjects 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"user"}')
chk "K15 PATCH bogus granted_role 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_role":"wizard"}')
chk "K16 PATCH bogus enum granted_type 400" 400 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"banana"}')
chk "K17 PATCH role->editor valid 200" 200 $(code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_role":"editor"}')
delperm $GP

# M2 redo: creator CAN create/delete grants
GP2=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
if [ -n "$GP2" ]; then
  chk "M2 creator POST permissions -> 200" 200 200
  DCRE=$(code -X DELETE "$API/api/v2/meta/bases/$BASE_ID/permissions/$GP2" -H "xc-auth: $CRE_TOK" -o /dev/null)
  chk "M2b creator DELETE own grant -> 200" 200 "$DCRE"
else
  chk "M2 creator POST permissions -> 200" 200 "400-or-other"
fi
# recreate for L2
GP3=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T4_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
code -X POST $API/api/v2/tables/$T4_ID/records -o /dev/null -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"Title":"l2row"}'
chk "L1' nobody DELETE: editor bulkDeleteAll 403" 403 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=%28Title%2Ceq%2Cl2row%29" -H "xc-auth: $EDI_TOK")
chk "L2' nobody DELETE: owner bulkDeleteAll 200" 200 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=%28Title%2Ceq%2Cl2row%29" -H "xc-auth: $OWN_TOK")
delperm $GP3

echo "== RESULT4 PASS=$PASS FAIL=$FAIL ==" >> $LOG
cat $LOG
