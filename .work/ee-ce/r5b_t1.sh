#!/bin/bash
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r5b_api.sh
TID=mrg0o01869uzttp
REC="$BASE/api/v2/tables/$TID/records"
J() { python3 -m json.tool 2>/dev/null || cat; }

echo "=== T1a-1: first insert UniqueCol=dup1"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"dup1","NormalCol":"n1"}'; echo
echo "=== T1a-2: duplicate insert UniqueCol=dup1 (expect FIELD_UNIQUE)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"dup1","NormalCol":"n2"}'; echo
echo "=== T1b-1: 'abc23505xyz' into NON-unique NormalCol (expect success, no misattribution)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"NormalCol":"abc23505xyz","UniqueCol":"only23505a"}'; echo
echo "=== T1b-2: duplicate insert value containing 23505 (expect FIELD_UNIQUE with value abc.. no? value=only23505a)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"only23505a","NormalCol":"x"}'; echo
echo "=== T1c-1: collide on UniqueCol only (UniqueCol2 fresh) - expect fieldName=UniqueCol"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"dup1","UniqueCol2":"fresh2a"}'; echo
echo "=== T1c-2: collide on UniqueCol2 only (UniqueCol fresh) - expect fieldName=UniqueCol2"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"fresh1b","UniqueCol2":"fresh2a"}'; echo
echo "=== T1d-1: empty string first insert UniqueCol=''"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"","NormalCol":"empty1"}'; echo
echo "=== T1d-2: empty string duplicate (expect violation)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"UniqueCol":"","NormalCol":"empty2"}'; echo
echo "=== T1e: explicit Id=9999 (expect ignored/auto-generated)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"Id":9999,"UniqueCol":"explicitid1"}'; echo
echo "=== T1e-2: repeat explicit Id=9999 (Id regenerated => unique dup only on UniqueCol)"
curl -s -w "\nHTTP=%{http_code}" -X POST "$REC" "${H[@]}" -d '{"Id":9999,"UniqueCol":"explicitid2"}'; echo
