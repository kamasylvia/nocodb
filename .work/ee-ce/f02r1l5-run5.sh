#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:180}"; }
perm() { curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "$1"; }
# T32 invalid entity
C=$(perm '{"entity":"field'"'"' --","entity_id":"x","permission":"RECORD_FIELD_EDIT","granted_type":"nobody"}'); t T32-inject-entity 400 $C "$(cat /tmp/o.json)"
# T33 invalid permission key
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"DROP TABLE x\",\"granted_type\":\"nobody\"}"); t T33-inject-permission 400 $C "$(cat /tmp/o.json)"
# T34 entity=table + RECORD_FIELD_EDIT (validation gap probe)
C=$(perm "{\"entity\":\"table\",\"entity_id\":\"$T1\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T34-table-entity-field-key "400?" $C "$(cat /tmp/o.json)"
T34ID=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))" 2>/dev/null)
# T35 invalid granted_role (accepted? semantics probe)
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"' OR 1=1 --\"}"); t T35-inject-granted_role "400?" $C "$(cat /tmp/o.json)"
T35ID=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))" 2>/dev/null)
if [ -n "$T35ID" ]; then
  C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"z"}'); t T35b-invalid-role-effect "403?(junk-role-deny)" $C "$(cat /tmp/o.json)"
  curl -s -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$T35ID -H "xc-auth: $OT" >/dev/null
fi
# T36 team subjects rejected
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"team\",\"id\":\"t1\"}]}"); t T36-team-subject 400 $C "$(cat /tmp/o.json)"
# T37 garbage subject type (filtered silently?)
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"agent\",\"id\":\"x\"},{\"type\":\"<script>\",\"id\":\"y\"}]}"); t T37-garbage-subject "400?" $C "$(cat /tmp/o.json)"
T37ID=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))" 2>/dev/null)
if [ -n "$T37ID" ]; then
  C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"z"}'); t T37b-empty-user-grant-effect "403?(deny-all)" $C "$(cat /tmp/o.json)"
  curl -s -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$T37ID -H "xc-auth: $OT" >/dev/null
fi
# T38 long string entity_id (255+)
LONG=$(printf 'a%.0s' $(seq 1 400))
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$LONG\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T38-long-entityid "400?(not-found)" $C "$(cat /tmp/o.json)"
# T39 cross-base entity_id
B2=$(curl -s -X POST $API/api/v2/meta/bases -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"name":"f02r1l5b2","title":"f02r1l5b2"}' | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
T3=$(curl -s -X POST $API/api/v2/meta/bases/$B2/tables -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"table_name":"X","title":"X","columns":[{"column_name":"F","title":"F","uidt":"SingleLineText"}]}' | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
B2COL=$(curl -s "$API/api/v2/meta/tables/$T3" -H "xc-auth: $OT" | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='F'][0])")
C=$(perm "{\"entity\":\"field\",\"entity_id\":\"$B2COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T39-crossbase-entityid "400?" $C "$(cat /tmp/o.json)"
T39ID=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))" 2>/dev/null)
[ -n "$T39ID" ] && curl -s -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$T39ID -H "xc-auth: $OT" >/dev/null
echo "T34ID=$T34ID" >> /tmp/f02r1l5.env
