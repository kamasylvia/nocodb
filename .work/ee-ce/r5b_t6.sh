#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
TID=mrg0o01869uzttp
REC="$BASE/api/v2/tables/$TID/records"

echo "=== T6a: mixed payload {Id, UniqueCol, Other(null)} — Id ignored? unknown 'Other' behavior? null writes NULL?"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"Id":777,"UniqueCol":"mix1","Other":null}'; echo
echo "=== T6b: read back row mix1"
curl -s "$REC?where=(UniqueCol,eq,mix1)" "${H[@]}" | python3 -m json.tool
echo "=== T6c: same mixed payload with fields-wrapped shape (per AGENTS: fields obj silently ignored -> expect NULL row or error)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"fields":{"UniqueCol":"wrap1"}}'; echo
echo "=== T6d: typecast=true insert: numeric value into text unique col"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC?typecast=true" "${H[@]}" -d '{"UniqueCol":12345}'; echo
echo "=== T6e: duplicate of typecast-inserted value (string form) expect FIELD_UNIQUE"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC?typecast=true" "${H[@]}" -d '{"UniqueCol":"12345"}'; echo
echo "=== T6f: typecast=false (default) numeric into text unique col — record behavior"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":67890}'; echo
echo "=== T6g: read back 12345/67890"
curl -s "$REC?where=(UniqueCol,in,12345,67890)&fields=Id,UniqueCol,NumCol" "${H[@]}" | python3 -m json.tool
