#!/bin/bash
# F02 R1 lane5 security test setup
API=http://localhost:8080
TS=$(date +%s)
OEMAIL="f02r1l5-o-${TS}@t.io"
EEMAIL="f02r1l5-e-${TS}@t.io"
PW="Passw0rd!123"
J=/usr/bin/python3

jqpy() { $J -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

signup() { # email -> token
  curl -s -X POST $API/api/v1/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" >/dev/null
  curl -s -X POST $API/api/v1/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | jqpy "d['token']"
}

OT=$(signup $OEMAIL)
echo "OT=$OT" > /tmp/f02r1l5.env
echo "EEMAIL=$EEMAIL" >> /tmp/f02r1l5.env
echo "PW=$PW" >> /tmp/f02r1l5.env
echo "TS=$TS" >> /tmp/f02r1l5.env
echo "owner token: ${OT:0:20}..."

# create base
BASE=$(curl -s -X POST $API/api/v1/meta/bases/ -H "xc-token: " -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"name":"f02r1l5"}' | jqpy "d['id']")
echo "BASE=$BASE" >> /tmp/f02r1l5.env
echo "base=$BASE"

# create table T1 with Title + Secret
T1=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"table_name":"T1","title":"T1","columns":[{"column_name":"Title","title":"Title","uidt":"SingleLineText"},{"column_name":"Secret","title":"Secret","uidt":"SingleLineText"}]}' | jqpy "d['id']")
echo "T1=$T1" >> /tmp/f02r1l5.env

# second table T2 for link
T2=$(curl -s -X POST $API/api/v2/meta/bases/$BASE/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"table_name":"T2","title":"T2","columns":[{"column_name":"Title","title":"Title","uidt":"SingleLineText"}]}' | jqpy "d['id']")
echo "T2=$T2" >> /tmp/f02r1l5.env

# link column on T1 -> T2
curl -s -X POST $API/api/v2/meta/tables/$T1/columns -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"uidt\":\"Links\",\"title\":\"Lnk\",\"column_name\":\"lnk\",\"parentId\":\"$T1\",\"childId\":\"$T2\",\"type\":\"mm\"}" >/dev/null

# list columns to get ids
COLS=$(curl -s $API/api/v2/meta/tables/$T1/columns -H "xc-auth: $OT")
SECRET_ID=$(echo "$COLS" | $J -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d if c['title']=='Secret'][0])")
LNK_ID=$(echo "$COLS" | $J -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d if c['title']=='Lnk'][0])")
echo "SECRET_ID=$SECRET_ID" >> /tmp/f02r1l5.env
echo "LNK_ID=$LNK_ID" >> /tmp/f02r1l5.env
echo "secret col=$SECRET_ID lnk col=$LNK_ID"

# seed rows
curl -s -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Title":"r1","Secret":"s1"}' >/dev/null
curl -s -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Title":"c1"}' >/dev/null

# editor signup
ET=$(signup $EEMAIL)
echo "ET=$ET" >> /tmp/f02r1l5.env
echo "editor token: ${ET:0:20}..."

# owner invites editor
EUID=$(curl -s $API/api/v2/users -H "xc-auth: $OT" | $J -c "import sys,json;d=json.load(sys.stdin);print([u['id'] for u in d['list'] if u['email']=='$EEMAIL'][0])" 2>/dev/null)
curl -s -X POST $API/api/v1/db/meta/bases/$BASE/users -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"email\":\"$EEMAIL\",\"roles\":\"editor\"}" >/dev/null
echo "invited editor uid=$EUID"
