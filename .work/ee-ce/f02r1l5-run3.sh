#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:200}"; }
# T21 reverse order: delete nobody grant, then role-editor grant stays; re-add nobody second? order in list = DB return order.
# Current: GRANT1(nobody) first, GRANT_ROLE second. Delete GRANT1 -> only role grant -> editor should write.
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$GRANT1 -H "xc-auth: $OT"); t T21a-delete-nobody 200 $C "$(cat /tmp/o.json)"
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"role-ok"}'); t T21b-editor-role-grant-only 200 $C "$(cat /tmp/o.json)"
# T22 add nobody SECOND -> grants[0] may still be role grant -> editor STILL allowed (lock-down failure)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T22a-add-nobody-second 200 $C "$(cat /tmp/o.json)"
GRANT_NOBODY2=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"lockfail"}'); t T22b-editor-nobody-second "expect-403-if-safe" $C "$(cat /tmp/o.json)"
echo "GRANT_NOBODY2=$GRANT_NOBODY2" >> /tmp/f02r1l5.env
# T23 v1 route with table id
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/noco/$BASE/$T1/1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"v1patch"}'); t T23-v1-patch-tableid 403 $C "$(cat /tmp/o.json)"
# T24 bulk upsert v2-style via v1 bulk with table id
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/bulk/noco/$BASE/$T1/upsert" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Id":1,"Secret":"upsert"}]'); t T24-v1-bulk-upsert 403 $C "$(cat /tmp/o.json)"
# T25 bulkUpdateAll with table id
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/bulk/noco/$BASE/$T1/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"all"}'); t T25-bulkUpdateAll 403 $C "$(cat /tmp/o.json)"
