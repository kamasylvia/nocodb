#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { # label expected code
  echo "[$1] expected=$2 got=$3 body=${4:0:160}"
}
# T0 fail-open baseline: editor patch Title
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Title":"r1e"}'); t T0-failopen-title 200 $C "$(cat /tmp/o.json)"
# T1 owner create nobody grant on Secret
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T1-create-nobody 201/200 $C "$(cat /tmp/o.json)"
GRANT1=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))")
echo "GRANT1=$GRANT1" >> /tmp/f02r1l5.env
# T2 editor patch Secret -> 403
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"hax"}'); t T2-editor-patch-secret 403 $C "$(cat /tmp/o.json)"
# T3 title-key payload
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"hax"}'); t T3-title-key 403 $C "$(cat /tmp/o.json)"
# T4 bulk array patch
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Id":1,"Secret":"hax"}]'); t T4-bulk-patch 403 $C "$(cat /tmp/o.json)"
# T5 insert single with Secret
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Title":"r2","Secret":"hax"}'); t T5-insert-secret 403 $C "$(cat /tmp/o.json)"
# T6 bulk insert
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Title":"r3","Secret":"hax"}]'); t T6-bulk-insert 403 $C "$(cat /tmp/o.json)"
# T7 mixed patch Title+Secret (whole request should 403, Title not written)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Title":"shouldnotwrite","Secret":"hax"}'); t T7-mixed-patch 403 $C "$(cat /tmp/o.json)"
V=$(curl -s "$API/api/v2/tables/$T1/records/1" -H "xc-auth: $ET" | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print(d['Title'])")
echo "   T7-verify-title-still=r1e got=$V"
# T8 owner bypass (super admin)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"owner-ok"}'); t T8-owner-bypass 200 $C "$(cat /tmp/o.json)"
# T9 editor permissionList -> 403
C=$(curl -s -o /tmp/o.json -w "%{http_code}" $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $ET"); t T9-editor-permissionList 403 $C "$(cat /tmp/o.json)"
# T10 editor permissionCreate -> 403
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}"); t T10-editor-permissionCreate 403 $C "$(cat /tmp/o.json)"
# T11 owner list permissions -> 200
C=$(curl -s -o /tmp/o.json -w "%{http_code}" $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT"); t T11-owner-permissionList 200 $C "$(cat /tmp/o.json)"
# T12 bulkUpdateAll (v1 bulk .../all)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/noco/$BASE/T1/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"hax-all"}'); t T12-bulkUpdateAll 403 $C "$(cat /tmp/o.json)"
# T13 v1 data insert
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/noco/$BASE/T1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Title":"v1r","Secret":"hax"}'); t T13-v1-insert 403 $C "$(cat /tmp/o.json)"
