#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:180}"; }
# create form view on T1
FV=$(curl -s -X POST $API/api/v2/meta/tables/$T1/views -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"title":"FV1","type":3}' | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
echo "FV=$FV"
# share it
UUID=$(curl -s -X POST $API/api/v2/meta/views/$FV/share -H "xc-auth: $OT" | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin).get('uuid',''))")
echo "UUID=$UUID"
# form columns: ensure Secret shown (default show=true? check view columns)
curl -s "$API/api/v2/meta/views/$FV" -H "xc-auth: $OT" | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print('view meta ok')" 2>/dev/null
COLS=$(curl -s "$API/api/v2/meta/views/$FV/columns" -H "xc-auth: $OT" 2>/dev/null)
# fallback v1 path
[ -z "$COLS" ] && COLS=$(curl -s "$API/api/v1/db/meta/views/$FV/columns" -H "xc-auth: $OT")
echo "$COLS" | /usr/bin/python3 -c "
import sys,json
d=json.load(sys.stdin)
rows=d.get('list',d) if isinstance(d,dict) else d
for c in rows: print(c.get('title'), c.get('show'), c.get('id'))
" 2>&1 | head -12
# anonymous submit WITH Secret (nobody grant on Secret active; Secret shown)
D=$(/usr/bin/python3 -c "import json;print(json.dumps({'data': json.dumps({'Title':'fromform','Secret':'formhax'})}))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/public/shared-view/$UUID/rows" -H 'Content-Type: application/json' -d "$D"); t T40-public-form-with-secret "403?" $C "$(cat /tmp/o.json)"
# anonymous submit without Secret
D=$(/usr/bin/python3 -c "import json;print(json.dumps({'data': json.dumps({'Title':'fromform2'})}))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/public/shared-view/$UUID/rows" -H 'Content-Type: application/json' -d "$D"); t T41-public-form-clean 200 $C "$(cat /tmp/o.json)"
# verify no formhax row landed
CNT=$(set -a; . ~/.zcode/.env; set +a; true)
echo "FV=$FV" >> /tmp/f02r1l5.env
echo "UUID=$UUID" >> /tmp/f02r1l5.env
