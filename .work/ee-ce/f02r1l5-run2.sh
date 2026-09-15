#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:200}"; }
BN=f02r1l5
# T12b bulkUpdateAll with title basename
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/noco/$BN/T1/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"hax-all"}'); t T12b-bulkUpdateAll 403 $C "$(cat /tmp/o.json)"
# T13b v1 insert with title basename
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/noco/$BN/T1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Title":"v1r","Secret":"hax"}'); t T13b-v1-insert 403 $C "$(cat /tmp/o.json)"
# T14 v1 data patch by rowId
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/noco/$BN/T1/1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"hax"}'); t T14-v1-patch 403 $C "$(cat /tmp/o.json)"
# T15 v1 bulk insert
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/bulk/noco/$BN/T1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Title":"b1","Secret":"hax"}]'); t T15-v1-bulk-insert 403 $C "$(cat /tmp/o.json)"
# T16 v1 bulk upsert
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/bulk/noco/$BN/T1/upsert" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Id":1,"Secret":"hax"}]'); t T16-v1-bulk-upsert 403 $C "$(cat /tmp/o.json)"
# T17 link: restrict Lnk then editor add link
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$LNK_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t T17a-create-lnk-nobody 200 $C "$(cat /tmp/o.json)"
GRANT_LNK=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/tables/$T1/links/$LNK_ID/records/1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '["<childRowId>"]'); t T17b-editor-add-link 403 $C "$(cat /tmp/o.json)"
# need child row id
CHILD=$(curl -s "$API/api/v2/tables/$T2/records?limit=1" -H "xc-auth: $ET" | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin)['list'][0]['Id'])")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/tables/$T1/links/$LNK_ID/records/1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d "[\"$CHILD\"]"); t T17c-editor-add-link-real 403 $C "$(cat /tmp/o.json)"
# T18 owner add link (bypass)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/tables/$T1/links/$LNK_ID/records/1" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "[\"$CHILD\"]"); t T18-owner-add-link 200 $C "$(cat /tmp/o.json)"
# T19 move route (only order col -> should be allowed for editor)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/tables/$T1/records/1/move" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"beforeRecordId":null,"afterRecordId":null,"position":null}'); t T19-move 200 $C "$(cat /tmp/o.json)"
# T20 duplicate grant ambiguity: add role:editor grant on Secret
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}"); t T20a-create-role-editor 200 $C "$(cat /tmp/o.json)"
GRANT_ROLE=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"ambig"}'); t T20b-editor-with-two-grants "ambig-semantics" $C "$(cat /tmp/o.json)"
echo "GRANT_LNK=$GRANT_LNK" >> /tmp/f02r1l5.env
echo "GRANT_ROLE=$GRANT_ROLE" >> /tmp/f02r1l5.env
