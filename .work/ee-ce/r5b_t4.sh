#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
COL=czg0xwu5saflmya   # f01r5b_tbl2.UniqueCol
echo "=== L1: PATCH unique=false (disable)"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":false}' | head -c 300; echo
echo "=== L2: PATCH unique=true (re-enable, no existing duplicates expected OK)"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":true}' | head -c 300; echo
echo "=== L3: insert dup rows then try enable on duplicated column (expect 400 with duplicate count)"
curl -s -o /dev/null -X POST "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d '{"UniqueCol":"lc1"}'
curl -s -o /dev/null -X POST "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d '{"UniqueCol":"lc1"}'
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":false}' | head -c 120; echo
echo "-- now column non-unique with 2 dup rows; re-enable (expect rejection):"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":true}' | head -c 400; echo
echo "-- cleanup dup row:"
DUP=$(curl -s "$BASE/api/v2/tables/mv107vl3aoaez51/records?where=(UniqueCol,eq,lc1)" "${H[@]}" | python3 -c "import sys,json;[print(r['Id']) for r in json.load(sys.stdin)['list']]" | tail -1)
curl -s -o /dev/null -w "del_dup=%{http_code}\n" -X DELETE "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d "{\"Id\":$DUP}"
echo "-- re-enable after dedup (expect OK):"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":true}' | head -c 200; echo
echo "=== L4: default-value + unique mutual exclusion (expect 400)"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","cdf":"xx"}' | head -c 300; echo
echo "=== L5: unique flag non-boolean 'false' string (expect 400)"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":"false"}' | head -c 300; echo
echo "=== L6: unsupported type unique (Attachment/Number?) try Number with unique"
curl -s -w "\nHTTP=%{http_code}" -X POST "$BASE/api/v2/meta/bases/p11r0acc87z1js1/tables/mv107vl3aoaez51/columns" "${H[@]}" -d '{"column_name":"UvNum","title":"UvNum","uidt":"Number","unique":true}' | head -c 300; echo
