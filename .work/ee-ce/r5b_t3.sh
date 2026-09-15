#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
TID=mrg0o01869uzttp
BULK="$BASE/api/v1/db/data/bulk/noco/p11r0acc87z1js1/$TID/all"
REC="$BASE/api/v2/tables/$TID/records"
SHOW() { curl -s "$REC?where=(UniqueCol,in,bulk_a1,bulk_a2,bulk_a3)&fields=Id,UniqueCol,UniqueCol2,NormalCol" "${H[@]}" | python3 -c "import sys,json;[print(r) for r in json.load(sys.stdin)['list']]"; }

echo "=== T3a: bulkUpdateAll collide (set UniqueCol=dup1 on bulk_a1,bulk_a2) expect 400 + unchanged"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BULK?where=(UniqueCol,in,bulk_a1,bulk_a2)" "${H[@]}" -H 'Content-Type: application/json' -d '{"UniqueCol":"dup1"}'; echo
echo "-- after:"; SHOW

echo "=== T3b: bulkUpdateAll self-value (bulk_a1 -> bulk_a1) expect success count, no violation"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BULK?where=(UniqueCol,eq,bulk_a1)" "${H[@]}" -H 'Content-Type: application/json' -d '{"UniqueCol":"bulk_a1"}'; echo

echo "=== T3c: bulkUpdateAll set NULL on 3 rows expect count=3"
curl -s -w "\nHTTP=%{http_code}" -X PATCH "$BULK?where=(UniqueCol,in,bulk_a1,bulk_a2,bulk_a3)" "${H[@]}" -H 'Content-Type: application/json' -d '{"UniqueCol":null}'; echo
echo "-- after (expect UniqueCol null, NormalCol intact):"; SHOW

echo "=== T3d: integrity full table"
curl -s "$REC?fields=Id,UniqueCol,UniqueCol2,NormalCol" "${H[@]}" | python3 -c "import sys,json;[print(r) for r in json.load(sys.stdin)['list']]"
