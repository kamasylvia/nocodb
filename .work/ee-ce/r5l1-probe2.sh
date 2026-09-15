#!/bin/zsh
. "$(dirname "$0")/r5l1-state.env"
B=http://localhost:8080
P="$B/api/v2/meta/bases/$BID/permissions"
BODY="$(dirname "$0")/r5l1-tmp.json"
PK="RECORD_FIELD_EDIT"

G=$(curl -s -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
GID=$(echo "$G" | jq -r '.id // ""')
echo "role grant created: $GID"

C=$(curl -s -o "$BODY" -w "%{http_code}" -X PATCH "$P/$GID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"granted_role":null}')
echo "G=$G"; echo "GID=$GID"
