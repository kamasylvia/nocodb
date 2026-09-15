#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:160}"; }
# T43 editor read restricted field still OK (only writes gated)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" "$API/api/v2/tables/$T1/records/1" -H "xc-auth: $ET"); t T43-editor-read-secret 200 $C "$(cat /tmp/o.json | head -c 60)"
# T44 permission PATCH by editor -> 403
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v2/meta/bases/$BASE/permissions/$GRANT3" -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"viewer"}'); t T44-editor-permissionUpdate 403 $C "$(cat /tmp/o.json)"
# T45 permission DELETE by editor -> 403
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X DELETE "$API/api/v2/meta/bases/$BASE/permissions/$GRANT3" -H "xc-auth: $ET"); t T45-editor-permissionDelete 403 $C "$(cat /tmp/o.json)"
# T46 owner update grant role->viewer then editor write should PASS (role grant viewer+)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v2/meta/bases/$BASE/permissions/$GRANT3" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"role","granted_role":"viewer"}'); t T46a-owner-update-grant 200 $C "$(cat /tmp/o.json)"
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"viewer-ok"}'); t T46b-editor-after-viewer-grant 200 $C "$(cat /tmp/o.json)"
# T47 cross-base permission update attempt (use base2 route with base1 grant id)
B2PERM=$(curl -s -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OT" 2>/dev/null; curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v2/meta/bases/$BASE/permissions/$GRANT3" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"nobody"}')
# T48 cleanup: delete grant -> fail-open full restore
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X DELETE "$API/api/v2/meta/bases/$BASE/permissions/$GRANT3" -H "xc-auth: $OT"); t T48a-delete-grant 200 $C "$(cat /tmp/o.json)"
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH $API/api/v2/tables/$T1/records -H "xc-auth: $ET" -H 'Content-Type: application/json' -d '{"Id":1,"Secret":"open-again"}'); t T48b-fail-open-restored 200 $C "$(cat /tmp/o.json)"
# T49 cross-base update: create perm in B2? base2 has no perms; try updating base1 grant from base2 context route
B2ID=$(curl -s "$API/api/v1/db/meta/projects" -H "xc-auth: $OT" 2>/dev/null | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print([b['id'] for b in d.get('list',d) if b.get('title')=='f02r1l5b2' or b.get('name')=='f02r1l5b2'][0])" 2>/dev/null)
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X PATCH "$API/api/v2/meta/bases/$B2ID/permissions/$GRANT3" -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"granted_type":"nobody"}'); t T49-crossbase-perm-update 400 $C "$(cat /tmp/o.json)"
