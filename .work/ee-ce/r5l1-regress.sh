#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
B=http://localhost:8080
J="$D/r5l1-tmp.json"
# F05 variables
C=$(curl -s -o "$J" -w "%{http_code}" "$B/api/v2/meta/bases/$BID/variables" -H "xc-auth: $TO"); echo "F05 list variables -> $C (expect 200)"
C=$(curl -s -o "$J" -w "%{http_code}" -X POST "$B/api/v2/meta/bases/$BID/variables" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"name":"R5Var","value":"v1"}'); echo "F05 create variable -> $C (expect 201/200)"
VID=$(jq -r '.id // empty' "$J")
# F07 snapshots
C=$(curl -s -o "$J" -w "%{http_code}" "$B/api/v2/meta/bases/$BID/snapshots" -H "xc-auth: $TO"); echo "F07 list snapshots -> $C (expect 200)"
# F10 dashboards
C=$(curl -s -o "$J" -w "%{http_code}" "$B/api/v2/meta/bases/$BID/dashboards" -H "xc-auth: $TO"); echo "F10 list dashboards -> $C (expect 200)"
# F08 base meta 读取（is_private 字段在响应中）
curl -s "$B/api/v2/meta/bases/$BID" -H "xc-auth: $TO" -o "$J"
echo "F08 base meta is_private field: $(jq -r 'has("is_private")' "$J") (expect true)"
# 回归：F02 grant 与 variables 并存——variables CRUD 不受 field grant 影响
C=$(curl -s -o "$J" -w "%{http_code}" -X PATCH "$B/api/v2/meta/bases/$BID/variables/$VID" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"value":"v2"}'); echo "F05 update variable -> $C (expect 200)"
[ -n "$VID" ] && curl -s -o /dev/null -w "F05 cleanup del var: %{http_code}\n" -X DELETE "$B/api/v2/meta/bases/$BID/variables/$VID" -H "xc-auth: $TO"
