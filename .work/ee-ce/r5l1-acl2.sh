#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
B=http://localhost:8080
P="$B/api/v2/meta/bases/$BID/permissions"
J="$D/r5l1-tmp.json"
PK="RECORD_FIELD_EDIT"
# 建 grant（owner）
GID=$(curl -s -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$NAME_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\"}" | jq -r '.id')
echo "grant: $GID"
C=$(curl -s -o "$J" -w "%{http_code}" -X DELETE "$P/$GID" -H "xc-auth: $TE")
echo "acl3 editor DELETE grant -> $C (expect 403) body: $(head -c 60 "$J")"
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TE" -H 'Content-Type: application/json' -d '{"enforce_for_form":true}')
echo "acl6 editor PATCH grant -> $C (expect 403) body: $(head -c 60 "$J")"
# 清场
curl -s -o /dev/null -w "cleanup del: %{http_code}\n" -X DELETE "$P/$GID" -H "xc-auth: $TO"
