#!/bin/bash
API=http://localhost:8080
source /tmp/f02r1l5.env
t() { echo "[$1] expected=$2 got=$3 body=${4:0:180}"; }
FV=$(curl -s -X POST $API/api/v2/meta/tables/$T1/forms -H "xc-auth: $OT" -H 'Content-Type: application/json' -d '{"title":"FV1"}' | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
UUID=$(curl -s -X POST $API/api/v2/meta/views/$FV/share -H "xc-auth: $OT" | /usr/bin/python3 -c "import sys,json;print(json.load(sys.stdin).get('uuid',''))")
echo "FV=$FV UUID=$UUID"
echo "FV=$FV" >> /tmp/f02r1l5.env; echo "UUID=$UUID" >> /tmp/f02r1l5.env
# anonymous submit with Secret (Secret shown by default, nobody grant active)
D=$(/usr/bin/python3 -c "import json;print(json.dumps({'data': json.dumps({'Title':'fromform','Secret':'formhax'})}))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/public/shared-view/$UUID/rows" -H 'Content-Type: application/json' -d "$D"); t T40-public-form-with-secret "403?" $C "$(cat /tmp/o.json)"
# anonymous submit without Secret
D=$(/usr/bin/python3 -c "import json;print(json.dumps({'data': json.dumps({'Title':'fromform2'})}))")
C=$(curl -s -o /tmp/o.json -w "%{http_code}" -X POST "$API/api/v2/public/shared-view/$UUID/rows" -H 'Content-Type: application/json' -d "$D"); t T41-public-form-clean 200 $C "$(cat /tmp/o.json)"
# check if formhax landed
set -a; . ~/.zcode/.env; set +a; TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null); while IFS='=' read -r k v; do case "$k" in DB_HOST|DB_PORT|DB_USER|DB_PASSWORD) export "$k=$v";; esac; done < <(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
/opt/homebrew/opt/libpq@18/bin/psql "postgresql://$DB_USER:$DB_PASSWORD@qnap.elf-balance.ts.net:$DB_PORT/nocodb-dev" -t -c "select \"Title\", \"Secret\" from t1_$T1 order by \"Id\" desc limit 3;" 2>/dev/null || /opt/homebrew/opt/libpq@18/bin/psql "postgresql://$DB_USER:$DB_PASSWORD@qnap.elf-balance.ts.net:$DB_PORT/nocodb-dev" -t -c "select table_name from information_schema.tables where table_name like '%mlw0jjyy%';"
