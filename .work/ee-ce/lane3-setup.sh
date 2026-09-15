#!/usr/bin/env bash
# lane3 F03 setup: signin 3 users, create base + 2 tables, invite editor/creator
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-env.sh
PW='Lane3F03!x'
signin() { curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | jq -r .token; }
export OT=$(signin lane3-f03-owner@t.local)
export ET=$(signin lane3-f03-editor@t.local)
export CT=$(signin lane3-f03-creator@t.local)
[ -n "$OT" ] && [ -n "$ET" ] && [ -n "$CT" ] && echo "tokens OK" || { echo "SIGNIN FAIL"; exit 1; }

# create base
BID=$(curl -s -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OT" -H 'Content-Type: application/json' \
  -d '{"title":"lane3-f03-ws","type":"database"}' | jq -r '.id')
[ "$BID" != "null" ] && [ -n "$BID" ] && echo "base=$BID" || { echo "BASE CREATE FAIL"; curl -s -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"title":"lane3-f03-ws2","type":"database"}'; exit 1; }

# create tables T1 (control) T2 (target)
mk() { curl -s -X POST $API/api/v2/meta/bases/$BID/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' \
  -d "{\"table_name\":\"$1\",\"title\":\"$1\",\"columns\":[{\"column_name\":\"Name\",\"title\":\"Name\",\"uidt\":\"SingleLineText\",\"pivot\":true}]}"; }
T1=$(mk Lane3T1 | jq -r .id); T2=$(mk Lane3T2 | jq -r .id)
echo "T1=$T1 T2=$T2"

# invite editor + creator
OUID=$(curl -s $API/api/v2/users/me -H "xc-auth: $OT" | jq -r .id)
inv() { curl -s -X POST $API/api/v2/base/$BID/users -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"roles\":\"$2\"}" | jq -c '{id,roles,email}' ; }
inv lane3-f03-editor@t.local editor
inv lane3-f03-creator@t.local creator

echo "BID=$BID" > /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
echo "T1=$T1" >> /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
echo "T2=$T2" >> /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/lane3-ids.env
