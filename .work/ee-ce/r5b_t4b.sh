#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
COL=czg0xwu5saflmya
T2=mvee  # unused
CODE() { tail -1; }
echo "=== L3-redo: disable -> insert 2 identical -> enable (expect 400 dup count)"
curl -s -o /dev/null -w "disable=%{http_code}\n" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":false}'
curl -s -o /dev/null -w "ins1=%{http_code}\n" -X POST "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d '{"UniqueCol":"lc1"}'
curl -s -o /dev/null -w "ins2=%{http_code}\n" -X POST "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d '{"UniqueCol":"lc1"}'
echo "-- enable with 2 dup rows (expect 400 'Found 2 duplicate values'):"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":true}'; echo
echo "-- DB state: rows must be unchanged (2 lc1 rows), still non-unique"
echo "-- cleanup: delete one lc1 row"
DUP=$(curl -s "$BASE/api/v2/tables/mv107vl3aoaez51/records?where=(UniqueCol,eq,lc1)" "${H[@]}" | python3 -c "import sys,json;[print(r['Id']) for r in json.load(sys.stdin)['list']]" | tail -1)
curl -s -o /dev/null -w "del_dup=%{http_code}\n" -X DELETE "$BASE/api/v2/tables/mv107vl3aoaez51/records" "${H[@]}" -d "{\"Id\":$DUP}"
echo "-- re-enable after dedup (expect 200 + uk_ index):"
curl -s -o /dev/null -w "enable=%{http_code}\n" -X PATCH "$BASE/api/v2/meta/columns/$COL" "${H[@]}" -d '{"title":"UniqueCol","unique":true}'
echo "=== L6-redo: add column route (v2 correct path) Number+unique"
curl -s -w "\nHTTP=%{http_code}" -X POST "$BASE/api/v2/meta/tables/mv107vl3aoaez51/columns" "${H[@]}" -d '{"column_name":"UvNum","title":"UvNum","uidt":"Number","unique":true}' | head -c 400; echo
echo "=== L7: delete column UvNum (if created) then verify index gone — see pg script"
