#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
B=http://localhost:8080
P="$B/api/v2/meta/bases/$BID/permissions"
J="$D/r5l1-tmp.json"; CD="$D/r5l1-code.txt"
PK="RECORD_FIELD_EDIT"

GID=$(curl -s -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}" | jq -r '.id // empty')
[ -z "$GID" ] && GID=$(curl -s "$P" -H "xc-auth: $TO" | jq -r --arg c "$SECRET_ID" '.[] | select(.entity_id==$c) | .id')
echo "role grant: $GID"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_role":null}')
echo "R4a1 PATCH granted_role:null -> $C (expect 400) body: $(head -c 90 "$J")"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_role":""}')
echo "R4a2 PATCH granted_role:'' -> $C (expect 400)"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"enforce_for_form":true}')
echo "R4a3 PATCH without granted_role -> $C (expect 200)"
curl -s "$P" -H "xc-auth: $TO" | jq -r --arg g "$GID" '.[] | select(.id==$g) | "  stored after a3: \(.granted_role) (expect creator) enforce_for_form: \(.enforce_for_form)"'

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_role":"editor"}')
echo "R4a4 PATCH granted_role:editor -> $C (expect 200)"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_role":null,"enforce_for_form":false}')
echo "R4a5 PATCH granted_role:null mixed -> $C (expect 400)"

C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_type":"nobody"}')
curl -s "$P" -H "xc-auth: $TO" | jq -r --arg g "$GID" --arg c "$C" '.[] | select(.id==$g) | "R4a6 PATCH->nobody http:\($c) type:\(.granted_type) stored_role:\(.granted_role // "null") subjects:\(.subjects|length) (expect nobody null 0)"'
