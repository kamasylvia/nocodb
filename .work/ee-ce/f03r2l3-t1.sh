#!/bin/bash
# T1 (v2): R1 fix verification — v1 data-route VISIBILITY enforcement + duplicate grant 400
# v1 route format: /api/v1/db/data/:workspaceId/:baseId/:tableId
set -u
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f03r2l3-env.sh
B=$BASE_ID; T=$T1_ID; W=w9qi3ljd
V1="$API/api/v1/db/data/$W/$B/$T"
CODE() { curl -s -m 15 -o /tmp/r1out.json -w "%{http_code}" "$@"; }
say() { echo "[$1] $2"; }

say seed "v1 insert (owner): $(CODE -X POST $V1 -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d '{"Name":"seed-v1"}')"
say seed "owner v1 GET baseline: $(CODE $V1 -H "xc-auth: $OWNER_TOKEN") (expect 200)"

G=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/$B/permissions -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}")
GID=$(echo "$G" | jq -r '.id // empty')
say grant "VISIBILITY nobody grant id=$GID"

ROW=$(curl -s -m 15 $API/api/v2/tables/$T/records -H "xc-auth: $OWNER_TOKEN" | jq -r '.list[0].Id')
say seed "rowId=$ROW"

say T1.1 "editor v2 GET records -> $(CODE $API/api/v2/tables/$T/records -H "xc-auth: $EDITOR_TOKEN") (expect 404)"
say T1.2 "editor v1 GET   -> $(CODE $V1 -H "xc-auth: $EDITOR_TOKEN") (expect 404)"
say T1.3 "editor v1 POST  -> $(CODE -X POST $V1 -H "xc-auth: $EDITOR_TOKEN" -H 'Content-Type: application/json' -d '{"Name":"x"}') (expect 404)"
say T1.4 "editor v1 PATCH -> $(CODE -X PATCH $V1/$ROW -H "xc-auth: $EDITOR_TOKEN" -H 'Content-Type: application/json' -d '{"Name":"y"}') (expect 404)"
say T1.5 "editor v1 DELETE-> $(CODE -X DELETE $V1/$ROW -H "xc-auth: $EDITOR_TOKEN") (expect 404)"
say T1.6 "creator v1 GET  -> $(CODE $V1 -H "xc-auth: $CREATOR_TOKEN") (expect 404)"
say T1.7 "owner  v1 GET   -> $(CODE $V1 -H "xc-auth: $OWNER_TOKEN") (expect 200)"
say T1.8 "editor v2 meta GET table -> $(CODE $API/api/v2/meta/tables/$T -H "xc-auth: $EDITOR_TOKEN") (expect 404)"

DUP=$(CODE -X POST $API/api/v2/meta/bases/$B/permissions -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}")
say T1.9 "duplicate VISIBILITY grant -> $DUP (expect 400) body: $(head -c 120 /tmp/r1out.json)"

say cleanup "delete grant -> $(CODE -X DELETE $API/api/v2/meta/bases/$B/permissions/$GID -H "xc-auth: $OWNER_TOKEN")"
say T1.10 "editor v1 GET after grant delete -> $(CODE $V1 -H "xc-auth: $EDITOR_TOKEN") (expect 200)"
say T1.11 "editor v2 GET after grant delete -> $(CODE $API/api/v2/tables/$T/records -H "xc-auth: $EDITOR_TOKEN") (expect 200)"
