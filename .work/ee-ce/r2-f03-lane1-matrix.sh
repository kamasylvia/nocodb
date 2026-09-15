#!/bin/bash
# R2 F03 lane1 — matrix runner. Sources env file (tokens/base/tables). No secrets.
source "$1"
PASS=0; FAIL=0; LOG=/tmp/f03lane1-results.txt; : > $LOG

chk() { # label expected actual(code)
  local L="$1" E="$2" A="$3"
  if [ "$E" == "$A" ]; then PASS=$((PASS+1)); echo "ok   $L -> $A" >> $LOG
  else FAIL=$((FAIL+1)); echo "FAIL $L expected=$E got=$A" >> $LOG; fi
}
code() { curl -s -o /tmp/f03lane1-body.json -w "%{http_code}" "$@"; }

V2REC() { echo "$API/api/v2/tables/$1/records"; }

# ---------- Phase A: fail-open baseline (no grants in fresh base) ----------
chk "A1 editor v2 insert Tasks (fail-open)" 200 $(code -X POST $(V2REC $T1_ID) -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"a1"}')
chk "A2 editor v2 list Tasks" 200 $(code $(V2REC $T1_ID) -H "xc-auth: $EDI_TOK")
ROW1=$(cat /tmp/f03lane1-body.json | python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
chk "A3 editor v2 delete row" 200 $(code -X DELETE $(V2REC $T1_ID)/records -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d "[{\"Id\":$ROW1}]")
chk "A4 editor v1 insert Tasks" 200 $(code -X POST $API/api/v1/db/data/noco/$BASE_ID/$T1_TITLE -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"a4"}')
chk "A5 creator v2 insert Tasks" 200 $(code -X POST $(V2REC $T1_ID) -H "xc-auth: $CRE_TOK" -H 'Content-Type: application/json' -d '{"Title":"a5"}')
chk "A6 owner v2 insert Tasks" 200 $(code -X POST $(V2REC $T1_ID) -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d '{"Title":"a6"}')

# ---------- Phase B: R1 fix — v1 VISIBILITY + multi-grant + duplicate ----------
# B1: nobody visibility on Secrets
G=$(curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T2_ID\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}")
GVIS_NOBODY=$(echo "$G" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
[ -z "$GVIS_NOBODY" ] && { echo "FAIL B0 create visibility nobody grant: $G" >> $LOG; FAIL=$((FAIL+1)); }
chk "B1 editor v1 GET list Secrets (nobody vis)" 404 $(code "$API/api/v1/db/data/noco/$BASE_ID/$T2_TITLE" -H "xc-auth: $EDI_TOK")
chk "B2 editor v1 POST insert Secrets (nobody vis)" 404 $(code -X POST "$API/api/v1/db/data/noco/$BASE_ID/$T2_TITLE" -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"x"}')
chk "B3 editor v2 GET records Secrets (nobody vis)" 404 $(code $(V2REC $T2_ID) -H "xc-auth: $EDI_TOK")
chk "B4 editor v2 meta table Secrets" 404 $(code "$API/api/v2/meta/tables/$T2_ID" -H "xc-auth: $EDI_TOK")
LIST_HAS=$(curl -s "$API/api/v2/meta/bases/$BASE_ID/tables?includeM2M=false" -H "xc-auth: $EDI_TOK" | python3 -c "import sys,json;print(sum(1 for t in json.load(sys.stdin)['list'] if t['id']=='$T2_ID'))")
chk "B5 editor table list excludes Secrets" 0 "$LIST_HAS"
chk "B6 owner v1 GET Secrets still 200" 200 $(code "$API/api/v1/db/data/noco/$BASE_ID/$T2_TITLE" -H "xc-auth: $OWN_TOK")
chk "B7 creator v2 GET Secrets (nobody vis) 404" 404 $(code $(V2REC $T2_ID) -H "xc-auth: $CRE_TOK")
curl -s -X DELETE "$API/api/v2/meta/bases/$BASE_ID/permissions/$GVIS_NOBODY" -H "xc-auth: $OWN_TOK" -o /dev/null
chk "B8 grant deleted -> editor v1 GET Secrets 200" 200 $(code "$API/api/v1/db/data/noco/$BASE_ID/$T2_TITLE" -H "xc-auth: $EDI_TOK")

# B9-11: multi-grant any-deny on Logs ADD
GR=$(curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
GR_ID=$(echo "$GR" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
GN=$(curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
echo "dup-post resp: $(echo "$GN" | head -c 120)" >> $LOG
chk "B9 duplicate (entity,entity_id,permission) POST -> 400" 400 $(echo "$GN" | python3 -c "import sys,json;print(400 if 'error' in json.load(sys.stdin) else 200)" 2>/dev/null)
chk "B10 editor insert Logs (role editor allow) 200" 200 $(code -X POST $(V2REC $T3_ID) -H "xc-auth: $EDI_TOK" -H 'Content-Type: application/json' -d '{"Title":"b10"}')
GN_ID=$(curl -s "$API/api/v2/meta/bases/$BASE_ID/permissions" -H "xc-auth: $OWN_TOK" | python3 -c "
import sys,json
for p in json.load(sys.stdin)['list']:
    if p['entity']=='table' and p['entity_id']=='$T3_ID' and p['permission']=='TABLE_RECORD_ADD' and p['granted_type']=='nobody': print(p['id']);break")
curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/permissions -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T3_ID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}" -o /tmp/f03lane1-dup.json
chk "B11 second ADD grant (nobody) also rejected" 400 $(python3 -c "import json;print(400 if 'error' in json.load(open('/tmp/f03lane1-dup.json')) else 200)")

echo "== RESULT PASS=$PASS FAIL=$FAIL ==" >> $LOG
tail -3 $LOG
