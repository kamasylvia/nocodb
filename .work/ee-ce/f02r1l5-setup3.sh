#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
J=/usr/bin/python3
jqpy() { $J -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

BASE=$(curl -s -X POST $API/api/v2/meta/bases -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"name":"f02r1l5","title":"f02r1l5"}' | jqpy "d['id']")
echo "BASE=$BASE" >> /tmp/f02r1l5.env
T1=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"table_name":"T1","title":"T1","columns":[{"column_name":"Title","title":"Title","uidt":"SingleLineText"},{"column_name":"Secret","title":"Secret","uidt":"SingleLineText"}]}' | jqpy "d['id']")
echo "T1=$T1" >> /tmp/f02r1l5.env
T2=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"table_name":"T2","title":"T2","columns":[{"column_name":"Title","title":"Title","uidt":"SingleLineText"}]}' | jqpy "d['id']")
echo "T2=$T2" >> /tmp/f02r1l5.env
LNK_ID=$(curl -s -X POST $API/api/v2/meta/tables/$T1/columns -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"uidt\":\"Links\",\"title\":\"Lnk\",\"column_name\":\"lnk\",\"parentId\":\"$T1\",\"childId\":\"$T2\",\"type\":\"mm\"}" | jqpy "d['id']")
COLS=$(curl -s $API/api/v2/meta/tables/$T1/columns -H "xc-auth: $OT")
SECRET_ID=$(echo "$COLS" | $J -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d if c['title']=='Secret'][0])")
echo "SECRET_ID=$SECRET_ID" >> /tmp/f02r1l5.env
echo "LNK_ID=$LNK_ID" >> /tmp/f02r1l5.env
echo "base=$BASE t1=$T1 secret=$SECRET_ID lnk=$LNK_ID"

R1=$(curl -s -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Title":"r1","Secret":"s1"}' | jqpy "d['Id']")
curl -s -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Title":"c1"}' >/dev/null
echo "R1=$R1" >> /tmp/f02r1l5.env

# invite editor
curl -s -X POST $API/api/v2/meta/bases/$BASE/users -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"email\":\"$EEMAIL\",\"roles\":\"editor\"}" | head -c 200; echo
