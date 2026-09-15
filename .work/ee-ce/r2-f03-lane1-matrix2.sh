#!/bin/bash
# R2 F03 lane1 — matrix part 2: R1 fix (v1-by-id), ADD/DELETE matrix, validation, Everyone semantics
source "$1"
PASS=0; FAIL=0; LOG=/tmp/f03lane1-results2.txt; : > $LOG
chk() { local L="$1" E="$2" A="$3"
  if [ "$E" == "$A" ]; then PASS=$((PASS+1)); echo "ok   $L -> $A" >> $LOG
  else FAIL=$((FAIL+1)); echo "FAIL $L expected=$E got=$A" >> $LOG; fi; }
code() { curl -s -o /tmp/f03lane1-b.json -w "%{http_code}" "$@"; }
mkgrant() { curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id','ERR:'+sys.stdin.read()[:60]))" 2>/dev/null; }
delgrant() { curl -s -X DELETE "$API/api/v2/meta/bases/$BASE_ID/permissions/$1" -H "xc-auth: $OWN_TOK" -o /dev/null; }
INS() { code -X POST $API/api/v2/tables/$1/records -H "xc-auth: $2" -H 'Content-Type: application/json' -d "{\"Title\":\"$3\"}"; }

V1REC() { echo "$API/api/v1/db/data/noco/$BASE_ID/$1"; }

# ---------- B': R1 fix re-verification via v1-by-id ----------
GV=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T2_ID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}")
chk "B'1 gate active: editor v1(by id) GET Secrets -> 404" 404 $(code "$(V1REC $T2_ID)" -H "xc-auth: $EDI_TOK")
chk "B'2 owner v1(by id) GET Secrets -> 200" 200 $(code "$(V1REC $T2_ID)" -H "xc-auth: $OWN_TOK")
chk "B'3 editor v1(by id) PATCH row -> 404" 404 $(code -X PATCH "$(V1REC $T2_ID)" -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"no"}')
delgrant $GV
chk "B'4 grant removed: editor v1(by id) GET Secrets -> 200" 200 $(code "$(V1REC $T2_ID)" -H "xc-auth: $EDI_TOK")

# ---------- C: TABLE_RECORD_ADD matrix on Tasks ----------
# existing rows cleanup: count then delete-all later
GA=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T1_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk "C1 nobody ADD: editor insert 403" 403 $(INS $T1_ID $EDI_TOK c1e)
chk "C2 nobody ADD: creator insert 403" 403 $(INS $T1_ID $CRE_TOK c1c)
chk "C3 nobody ADD: owner insert 200" 200 $(INS $T1_ID $OWN_TOK c1o)
chk "C4 nobody ADD: editor bulk insert 403" 403 $(code -X POST $API/api/v2/tables/$T1_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '[{"Title":"c4a"},{"Title":"c4b"}]')
# PATCH (update) must NOT require ADD
RID=$(curl -s "$API/api/v2/tables/$T1_ID/records?limit=1" -H "xc-auth: $OWN_TOK" | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "C5 nobody ADD: editor PATCH row (update ok) 200" 200 $(code -X PATCH $API/api/v2/tables/$T1_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "{\"Id\":$RID,\"Title\":\"c5\"}")
# bulkUpsert pure-update batch without ADD
chk "C6 nobody ADD: editor bulkUpsert pure-update 200" 200 $(code -X POST "$API/api/v2/tables/$T1_ID/records?undo=1" -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$RID,\"Title\":\"c6\"}]")
# switch to role:editor via PATCH on the grant
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"editor"}' -o /dev/null
chk "C7 role:editor ADD: editor insert 200" 200 $(INS $T1_ID $EDI_TOK c7e)
chk "C8 role:editor ADD: creator insert 200" 200 $(INS $T1_ID $CRE_TOK c7c)
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_role":"creator"}' -o /dev/null
chk "C9 role:creator ADD: editor insert 403" 403 $(INS $T1_ID $EDI_TOK c9e)
chk "C10 role:creator ADD: creator insert 200" 200 $(INS $T1_ID $CRE_TOK c10c)
# user grant on editor
EUID=$(curl -s "$API/api/v2/meta/bases/$BASE_ID/users" -H "xc-auth: $OWN_TOK" | python3 -c "
import sys,json
for u in json.load(sys.stdin)['list']:
  if u.get('email')=='$EDITOR': print(u['id']);break")
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GA" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "{\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID\"}]}" -o /dev/null
chk "C11 user(editor) ADD: editor insert 200" 200 $(INS $T1_ID $EDI_TOK c11e)
chk "C12 user(editor) ADD: creator insert 403" 403 $(INS $T1_ID $CRE_TOK c12c)
delgrant $GA
chk "C13 grant deleted: editor insert (fail-open restored) 200" 200 $(INS $T1_ID $EDI_TOK c13e)

# ---------- D: TABLE_RECORD_DELETE matrix on Notes ----------
GD=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T4_ID\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}")
ROWN=$(code -X POST $API/api/v2/tables/$T4_ID/records -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"Title":"d-row"}' >/dev/null; curl -s "$API/api/v2/tables/$T4_ID/records?limit=1" -H "xc-auth: $OWN_TOK" | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "D1 nobody DELETE: editor v2 delete row 403" 403 $(code -X DELETE $API/api/v2/tables/$T4_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROWN}]")
chk "D2 nobody DELETE: editor v1(by id) delete row 403" 403 $(code -X DELETE "$(V1REC $T4_ID)/$ROWN" -H "xc-auth: $EDI_TOK")
chk "D3 nobody DELETE: creator v2 delete row 403" 403 $(code -X DELETE $API/api/v2/tables/$T4_ID/records -H "xc-auth: $CRE_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROWN}]")
chk "D4 nobody DELETE: owner v2 delete row 200" 200 $(code -X DELETE $API/api/v2/tables/$T4_ID/records -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROWN}]")
chk "D5 nobody DELETE: editor bulkDeleteAll (where) 403" 403 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=(Title,like,d%)" -H "xc-auth: $EDI_TOK")
chk "D6 nobody DELETE: owner bulkDeleteAll 200" 200 $(code -X DELETE "$API/api/v2/tables/$T4_ID/records?where=(Title,like,d%)" -H "xc-auth: $OWN_TOK")
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GD" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"editor"}' -o /dev/null
ROWN2=$(code -X POST $API/api/v2/tables/$T4_ID/records -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"Title":"d-row2"}' >/dev/null; curl -s "$API/api/v2/tables/$T4_ID/records?limit=1" -H "xc-auth: $OWN_TOK" | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "D7 role:editor DELETE: editor delete 200" 200 $(code -X DELETE $API/api/v2/tables/$T4_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROWN2}]")
delgrant $GD
ROWN3=$(code -X POST $API/api/v2/tables/$T4_ID/records -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"Title":"d-row3"}' >/dev/null; curl -s "$API/api/v2/tables/$T4_ID/records?limit=1" -H "xc-auth: $OWN_TOK" | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "D8 deleted grant: editor delete fail-open 200" 200 $(code -X DELETE $API/api/v2/tables/$T4_ID/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROWN3}]")

# ---------- E: VISIBILITY semantics ----------
GV2=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T2_ID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")
chk "E1 vis role:viewer: editor v2 GET 200" 200 $(code $API/api/v2/tables/$T2_ID/records -H "xc-auth: $EDI_TOK")
code -X PATCH "$API/api/v2/meta/bases/$BASE_ID/permissions/$GV2" -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"granted_type":"user","subjects":[{"type":"user","id":"'$EUID'"}]}' -o /dev/null
chk "E2 vis user(editor): editor GET 200" 200 $(code $API/api/v2/tables/$T2_ID/records -H "xc-auth: $EDI_TOK")
chk "E3 vis user(editor): creator GET 404" 404 $(code $API/api/v2/tables/$T2_ID/records -H "xc-auth: $CRE_TOK")
delgrant $GV2
chk "E4 Everyone(=no grant): creator GET 200" 200 $(code $API/api/v2/tables/$T2_ID/records -H "xc-auth: $CRE_TOK")

echo "== RESULT2 PASS=$PASS FAIL=$FAIL ==" >> $LOG
cat $LOG
