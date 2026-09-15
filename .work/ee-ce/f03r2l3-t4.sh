#!/bin/bash
# T4b: update-side nobody+subjects + T5b: public form enforce_for_form (fixed routes)
set -u
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f03r2l3-env.sh
B=$BASE_ID; T=$T1_ID
PERM="$API/api/v2/meta/bases/$B/permissions"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1 = $2"; else FAIL=$((FAIL+1)); echo "FAIL $1 got=$2 want=$3"; fi }
post() { curl -s -m 15 -o /tmp/tb.json -w "%{http_code}" -X POST $PERM -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d "$1"; }
patchg() { curl -s -m 15 -o /tmp/tb.json -w "%{http_code}" -X PATCH $PERM/$1 -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d "$2"; }
delg() { curl -s -m 15 -o /dev/null -X DELETE $PERM/$1 -H "xc-auth: $OWNER_TOKEN"; }
cleanup() { for g in $(curl -s -m 15 $PERM -H "xc-auth: $OWNER_TOKEN" | jq -r '.[]? | select(.entity_id=="'"$T"'") | .id'); do delg $g; done; }
cleanup

echo "=== T4b update-side nobody + subjects ==="
G=$(post "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"nobody\"}"); G=$(jq -r '.id' /tmp/tb.json)
echo "nobody grant id=$G"
chk u.nobody_add_subj "$(patchg $G '{"granted_type":"nobody","subjects":[{"type":"user","id":"x"}]}')" 400
chk u.nobody_stays_ok  "$(patchg $G '{}')" 200
delg $G

echo "=== T5b public form ==="
VW=$(curl -s -m 15 -X POST "$API/api/v2/meta/tables/$T/forms" -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d '{"title":"f03r2l3form"}')
VWID=$(echo "$VW" | jq -r '.id // empty')
echo "form view id=$VWID"
SH=$(curl -s -m 15 -X POST "$API/api/v2/meta/views/$VWID/share" -H "xc-auth: $OWNER_TOKEN")
UUID=$(echo "$SH" | jq -r '.uuid // empty')
echo "uuid=$UUID"
anonsubmit() { curl -s -m 15 -o /tmp/t5.json -w "%{http_code}" -X POST "$API/api/v2/public/shared-view/$UUID/rows" -H 'Content-Type: application/json' -d '{"data":{"Name":"anon"}}'; }
c=$(anonsubmit); chk t5.baseline "$c" 200
echo "baseline body: $(head -c 120 /tmp/t5.json)"

G=$(post "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}"); G=$(jq -r '.id' /tmp/tb.json)
chk t5.role_ff_default "$(anonsubmit)" 403
chk t5.ff_false        "$(patchg $G '{"enforce_for_form":false}')" 200
chk t5.ff_false_submit "$(anonsubmit)" 200
delg $G
cleanup

G=$(post "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}"); G=$(jq -r '.id' /tmp/tb.json)
chk t5.nobody_default "$(anonsubmit)" 403
chk t5.nobody_ff_false "$(patchg $G '{"enforce_for_form":false}')" 200
chk t5.nobody_ff_false_submit "$(anonsubmit)" 403
delg $G
cleanup
echo "RESULT pass=$PASS fail=$FAIL"
