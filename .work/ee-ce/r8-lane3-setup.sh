#!/bin/bash
API=http://localhost:8080
OWN=f02r8l3own@test.local
EDT=f02r8l3edt@test.local
CRT=f02r8l3crt@test.local
PW='Lane3R8!x'
signin(){ curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'; }
OT=$(signin $OWN); ET=$(signin $EDT); CT=$(signin $CRT)
echo "$OT" > /tmp/f02r8l3_ot; echo "$ET" > /tmp/f02r8l3_et; echo "$CT" > /tmp/f02r8l3_ct
AH="xc-auth: $OT"; CT_H='Content-Type: application/json'

# create base
BASE=$(curl -s -X POST $API/api/v2/meta/bases/ -H "$AH" -H "$CT_H" -d '{"name":"F02R8L3","type":"database"}' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
echo "BASE=$BASE"; echo "$BASE" > /tmp/f02r8l3_base

# create T2 (Refs) then T1 (Sheet1)
T2=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "$AH" -H "$CT_H" -d '{"table_name":"Refs","columns":[{"column_name":"name","uidt":"SingleLineText"}]}' | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["id"])')
T1=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "$AH" -H "$CT_H" -d '{"table_name":"Sheet1","columns":[{"column_name":"Title","uidt":"SingleLineText"},{"column_name":"Secret","uidt":"SingleLineText"}]}' | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["id"])')
echo "T1=$T1 T2=$T2"; echo "$T1" > /tmp/f02r8l3_t1; echo "$T2" > /tmp/f02r8l3_t2

# columns of T1
curl -s $API/api/v2/meta/tables/$T1 -H "$AH" > /tmp/f02r8l3_t1meta
python3 - <<PY
import json
d=json.load(open('/tmp/f02r8l3_t1meta'))
for c in d['columns']: print(c['title'], c['id'], c['uidt'])
PY

# invite editor + creator
echo "invite edt: $(curl -s -X POST $API/api/v2/meta/bases/$BASE/users -H "$AH" -H "$CT_H" -d "{\"email\":\"$EDT\",\"roles\":\"editor\"}" | head -c 150)"
echo "invite crt: $(curl -s -X POST $API/api/v2/meta/bases/$BASE/users -H "$AH" -H "$CT_H" -d "{\"email\":\"$CRT\",\"roles\":\"creator\"}" | head -c 150)"

# insert rows into Refs
for n in R1 R2; do
  curl -s -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H "$CT_H" -d "{\"name\":\"$n\"}" -o /dev/null -w "ref $n: %{http_code}\n"
done
# insert a row into Sheet1
curl -s -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $OT" -H "$CT_H" -d '{"Title":"row1","Secret":"s1"}' -o /tmp/f02r8l3_row1 -w "sheet1 row1: %{http_code}\n"; cat /tmp/f02r8l3_row1 | head -c 200; echo
