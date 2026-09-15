#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:200}"; }
# clean: delete role grant + nobody2, recreate single nobody on Secret
curl -s -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$GRANT_ROLE -H "xc-auth: $OT" >/dev/null
curl -s -X DELETE $API/api/v2/meta/bases/$BASE/permissions/$GRANT_NOBODY2 -H "xc-auth: $OT" >/dev/null
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST $API/api/v2/meta/bases/$BASE/permissions -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"); t C1-recreate-nobody 200 $C "$(cat /tmp/o.json)"
GRANT3=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/o.json')).get('id',''))")
echo "GRANT3=$GRANT3" >> /tmp/f02r1l5.env
# verify v2 still blocked
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"x"}'); t C2-v2-patch 403 $C "$(cat /tmp/o.json)"
# T26 v1 patch single row (clean)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/noco/$BASE/$T1/1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"v1bypass"}'); t T26-v1-patch 403 $C "$(cat /tmp/o.json)"
# T27 v1 bulkUpdateAll (clean)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/bulk/noco/$BASE/$T1/all" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Secret":"allbypass"}'); t T27-bulkUpdateAll 403 $C "$(cat /tmp/o.json)"
# T28 v1 bulk upsert (clean)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/bulk/noco/$BASE/$T1/upsert" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Id":1,"Secret":"upsertbypass"}]'); t T28-v1-bulk-upsert 403 $C "$(cat /tmp/o.json)"
# T29 v1 bulk update
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v1/db/data/bulk/noco/$BASE/$T1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Id":1,"Secret":"bulkupd"}]'); t T29-v1-bulk-update 403 $C "$(cat /tmp/o.json)"
# T30 v1 bulk insert (clean)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v1/db/data/bulk/noco/$BASE/$T1" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '[{"Title":"bi","Secret":"bi"}]'); t T30-v1-bulk-insert 403 $C "$(cat /tmp/o.json)"
# T31 verify DB actually unchanged
V=$(curl -s "$API/api/v2/tables/$T1/records/1" -H "xc-auth: $OT" | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print(d['Secret'])")
echo "   T31-db-secret=$V (expect owner-ok)"
