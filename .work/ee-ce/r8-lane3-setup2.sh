#!/bin/bash
API=http://localhost:8080
OWN=f02r8l3own@test.local
EDT=f02r8l3edt@test.local
CRT=f02r8l3crt@test.local
PW='Lane3R8!x'
signin(){ curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'; }
OT=$(signin $OWN); echo "$OT" > /tmp/f02r8l3_ot
BASE=$(cat /tmp/f02r8l3_base)
AH="xc-auth: $OT"; CT_H='Content-Type: application/json'

T2RESP=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "$AH" -H "$CT_H" -d '{"table_name":"Refs","columns":[{"column_name":"name","uidt":"SingleLineText"}]}')
T2=$(echo "$T2RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
T1RESP=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "$AH" -H "$CT_H" -d '{"table_name":"Sheet1","columns":[{"column_name":"Title","uidt":"SingleLineText"},{"column_name":"Secret","uidt":"SingleLineText"}]}')
T1=$(echo "$T1RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "T1=$T1 T2=$T2"; echo "$T1" > /tmp/f02r8l3_t1; echo "$T2" > /tmp/f02r8l3_t2

curl -s $API/api/v2/meta/tables/$T1 -H "$AH" > /tmp/f02r8l3_t1meta
python3 - <<PY
import json
d=json.load(open('/tmp/f02r8l3_t1meta'))
for c in d['columns']: print(c['title'], c['id'], c['uidt'])
PY

echo "invite edt: $(curl -s -X POST $API/api/v2/meta/bases/$BASE/users -H "$AH" -H "$CT_H" -d "{\"email\":\"$EDT\",\"roles\":\"editor\"}" | head -c 200)"
echo "invite crt: $(curl -s -X POST $API/api/v2/meta/bases/$BASE/users -H "$AH" -H "$CT_H" -d "{\"email\":\"$CRT\",\"roles\":\"creator\"}" | head -c 200)"

for n in R1 R2; do
  curl -s -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H "$CT_H" -d "{\"name\":\"$n\"}" -o /dev/null -w "ref $n: %{http_code}\n"
done
curl -s -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $OT" -H "$CT_H" -d '{"Title":"row1","Secret":"s1"}' -o /tmp/f02r8l3_row1 -w "sheet1 row1: %{http_code}\n"; head -c 250 /tmp/f02r8l3_row1; echo
