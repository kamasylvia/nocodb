#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
TID=mrg0o01869uzttp
REC="$BASE/api/v2/tables/$TID/records"
CNT() { curl -s "$REC?fields=Id" "${H[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['pageInfo']['totalRows'])"; }

echo "=== T2-0 baseline count: $(CNT)"

echo "=== T2a: bulk insert 3 fresh rows (expect all OK)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '[{"UniqueCol":"bulk_a1"},{"UniqueCol":"bulk_a2"},{"UniqueCol":"bulk_a3"}]'; echo
echo "count after a: $(CNT)"

echo "=== T2b: bulk [fresh, COLLIDE-dup1, fresh] (expect rollback: no row persisted)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '[{"UniqueCol":"bulk_b1"},{"UniqueCol":"dup1"},{"UniqueCol":"bulk_b3"}]'; echo
echo "count after b: $(CNT)"
echo "-- verify bulk_b1/bulk_b3 absent:"
curl -s "$REC?where=(UniqueCol,eq,bulk_b1)" "${H[@]}" | python3 -c "import sys,json;print('bulk_b1 rows:',json.load(sys.stdin)['pageInfo']['totalRows'])"
curl -s "$REC?where=(UniqueCol,eq,bulk_b3)" "${H[@]}" | python3 -c "import sys,json;print('bulk_b3 rows:',json.load(sys.stdin)['pageInfo']['totalRows'])"

echo "=== T2c: intra-batch duplicate [x,x] (expect rollback all)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '[{"UniqueCol":"bulk_c1"},{"UniqueCol":"bulk_c1"},{"UniqueCol":"bulk_c9"}]'; echo
echo "count after c: $(CNT)"
curl -s "$REC?where=(UniqueCol,eq,bulk_c9)" "${H[@]}" | python3 -c "import sys,json;print('bulk_c9 rows:',json.load(sys.stdin)['pageInfo']['totalRows'])"

echo "=== T2d: UNDO collision interception"
echo "-- delete row Id=10 (UniqueCol=explicitid2)"
curl -s -w "\nHTTP=%{http_code}" -X DELETE "$REC" "${H[@]}" -d '{"Id":10}'; echo
echo "-- new row takes value explicitid2"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"explicitid2","NormalCol":"usurper"}'; echo
echo "-- undo replay old row Id=10 UniqueCol=explicitid2 (expect FIELD_UNIQUE, no partial)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC?undo=true" "${H[@]}" -d '{"Id":10,"UniqueCol":"explicitid2","NormalCol":"pre-delete"}'; echo
echo "-- verify Id=10 NOT recreated:"
curl -s "$REC?where=(Id,eq,10)" "${H[@]}" | python3 -c "import sys,json;print('Id=10 rows:',json.load(sys.stdin)['pageInfo']['totalRows'])"
echo "count after d: $(CNT)"

echo "=== T2e: concurrency 5 parallel inserts same value 'race_v1' (expect exactly 1 success 4 FIELD_UNIQUE)"
for i in 1 2 3 4 5; do
  curl -s -o /tmp/r5b_race_$i.json -w "%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"race_v1","NormalCol":"r'$i'"}' > /tmp/r5b_race_code_$i.txt &
done
wait
for i in 1 2 3 4 5; do printf "req$i: code=%s body=%s\n" "$(cat /tmp/r5b_race_code_$i.txt)" "$(cat /tmp/r5b_race_$i.json)"; done
echo "-- race_v1 total rows (expect 1):"
curl -s "$REC?where=(UniqueCol,eq,race_v1)" "${H[@]}" | python3 -c "import sys,json;print(json.load(sys.stdin)['pageInfo']['totalRows'])"
