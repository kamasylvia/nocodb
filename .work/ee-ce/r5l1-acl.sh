#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
B=http://localhost:8080
P="$B/api/v2/meta/bases/$BID/permissions"
J="$D/r5l1-tmp.json"
PK="RECORD_FIELD_EDIT"

# editor list grants -> 200（permissionList editor+）
C=$(curl -s -o "$J" -w "%{http_code}" "$P" -H "xc-auth: $TE")
echo "acl1 editor LIST grants -> $C (expect 200)"
# editor create grant -> 403（permissionCreate creator+）
C=$(curl -s -o "$J" -w "%{http_code}" -X POST "$P" -H "xc-auth: $TE" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAME_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\"}")
echo "acl2 editor CREATE grant -> $C (expect 403)"
# editor delete -> 403
GID=$(curl -s "$P" -H "xc-auth: $TO" | jq -r '.[0].id // empty')
if [ -n "$GID" ]; then
  C=$(curl -s -o "$J" -w "%{http_code}" -X DELETE "$P/$GID" -H "xc-auth: $TE")
  echo "acl3 editor DELETE grant -> $C (expect 403)"
fi
# creator create -> 200
C=$(curl -s -o "$J" -w "%{http_code}" -X POST "$P" -H "xc-auth: $TC" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAME_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\"}")
echo "acl4 creator CREATE grant -> $C (expect 200)"
NID=$(jq -r '.id // empty' "$J")
# creator delete -> 200
C=$(curl -s -o "$J" -w "%{http_code}" -X DELETE "$P/$NID" -H "xc-auth: $TC")
echo "acl5 creator DELETE grant -> $C (expect 200)"
# editor PATCH existing -> 403
GID=$(curl -s "$P" -H "xc-auth: $TO" | jq -r '.[0].id // empty')
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TE" -H 'Content-Type: application/json' -d '{"enforce_for_form":true}')
echo "acl6 editor PATCH grant -> $C (expect 403)"
