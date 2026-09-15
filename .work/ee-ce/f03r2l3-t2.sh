#!/bin/bash
# T2: full matrix — ADD/DELETE grants x roles x ops (v2 primary, v1 spot) + fail-open
set -u
. /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f03r2l3-env.sh
B=$BASE_ID; T=$T1_ID; T2=$T2_ID; W=w9qi3ljd
V1="$API/api/v1/db/data/$W/$B/$T"
V2="$API/api/v2/tables/$T/records"
PERM="$API/api/v2/meta/bases/$B/permissions"
PASS=0; FAIL=0
chk() { # chk <name> <got> <want>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1 = $2"; else FAIL=$((FAIL+1)); echo "FAIL $1 got=$2 want=$3"; fi
}
mkgrant() { curl -s -m 15 -X POST $PERM -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d "$1" | jq -r '.id // empty'; }
rmgrant() { curl -s -m 15 -o /dev/null -X DELETE $PERM/$1 -H "xc-auth: $OWNER_TOKEN"; }

# clean any leftover grants on Alpha
for g in $(curl -s -m 15 $PERM -H "xc-auth: $OWNER_TOKEN" | jq -r '.[]? | select(.entity_id=="'"$T"'") | .id'); do rmgrant $g; done

ins() { curl -s -m 15 -o /dev/null -w "%{http_code}" -X POST $V2 -H "xc-auth: $1" -H 'Content-Type: application/json' -d '{"Name":"m"}'; }
insbulk() { curl -s -m 15 -o /dev/null -w "%{http_code}" -X POST $V2 -H "xc-auth: $1" -H 'Content-Type: application/json' -d '[{"Name":"b1"},{"Name":"b2"}]'; }
upd() { local id=$(curl -s -m 15 $API/api/v2/tables/$T/records -H "xc-auth: $OWNER_TOKEN" | jq -r '.list[0].Id'); curl -s -m 15 -o /dev/null -w "%{http_code}" -X PATCH $V2 -H "xc-auth: $1" -H 'Content-Type: application/json' -d "{\"Id\":$id,\"Name\":\"u\"}"; }
del() { local id=$(curl -s -m 15 $API/api/v2/tables/$T/records -H "xc-auth: $OWNER_TOKEN" | jq -r '.list[-1].Id'); curl -s -m 15 -o /dev/null -w "%{http_code}" -X DELETE $V2 -H "xc-auth: $1" -H 'Content-Type: application/json' -d "{\"Id\":$id}"; }
delbulk() { local id=$(curl -s -m 15 $API/api/v2/tables/$T/records -H "xc-auth: $OWNER_TOKEN" | jq -r '.list[-1].Id'); curl -s -m 15 -o /dev/null -w "%{http_code}" -X DELETE $V2 -H "xc-auth: $1" -H 'Content-Type: application/json' -d "[{\"Id\":$id}]"; }
delall() { curl -s -m 20 -o /dev/null -w "%{http_code}" -X DELETE "$API/api/v1/db/data/bulk/$W/$B/Alpha/all" -H "xc-auth: $1" -H 'Content-Type: application/json' -d '{}'; }
v1ins() { curl -s -m 15 -o /dev/null -w "%{http_code}" -X POST $V1 -H "xc-auth: $1" -H 'Content-Type: application/json' -d '{"Name":"v1"}'; }
v1del() { local id=$(curl -s -m 15 $API/api/v2/tables/$T/records -H "xc-auth: $OWNER_TOKEN" | jq -r '.list[-1].Id'); curl -s -m 15 -o /dev/null -w "%{http_code}" -X DELETE $V1/$id -H "xc-auth: $1"; }
vis() { curl -s -m 15 -o /dev/null -w "%{http_code}" $API/api/v2/tables/$T/records -H "xc-auth: $1"; }

echo "=== baseline (no grants) fail-open ==="
chk base.owner.ins  "$(ins $OWNER_TOKEN)"  200
chk base.editor.ins "$(ins $EDITOR_TOKEN)" 200
chk base.creator.ins "$(ins $CREATOR_TOKEN)" 200
chk base.editor.upd "$(upd $EDITOR_TOKEN)" 200
chk base.editor.del "$(del $EDITOR_TOKEN)" 200
chk base.editor.vis "$(vis $EDITOR_TOKEN)" 200

echo "=== ADD nobody ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk addnobody.editor.ins  "$(ins $EDITOR_TOKEN)"  403
chk addnobody.creator.ins "$(ins $CREATOR_TOKEN)" 403
chk addnobody.owner.ins   "$(ins $OWNER_TOKEN)"   200
chk addnobody.editor.bulk "$(insbulk $EDITOR_TOKEN)" 403
chk addnobody.editor.upd  "$(upd $EDITOR_TOKEN)"  200
chk addnobody.editor.del  "$(del $EDITOR_TOKEN)"  200
chk addnobody.editor.vis  "$(vis $EDITOR_TOKEN)"  200
rmgrant $G

echo "=== ADD role:editor ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
chk addred.editor.ins  "$(ins $EDITOR_TOKEN)"   200
chk addred.creator.ins "$(ins $CREATOR_TOKEN)"  200
chk addred.owner.ins   "$(ins $OWNER_TOKEN)"    200
rmgrant $G

echo "=== ADD role:creator ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk addrc.editor.ins  "$(ins $EDITOR_TOKEN)"   403
chk addrc.creator.ins "$(ins $CREATOR_TOKEN)"  200
chk addrc.owner.ins   "$(ins $OWNER_TOKEN)"    200
chk addrc.editor.bulk "$(insbulk $EDITOR_TOKEN)" 403
rmgrant $G

echo "=== DELETE nobody ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"nobody\"}")
chk delnobody.editor.del   "$(del $EDITOR_TOKEN)"   403
chk delnobody.editor.delb  "$(delbulk $EDITOR_TOKEN)" 403
chk delnobody.creator.del  "$(del $CREATOR_TOKEN)"  403
chk delnobody.owner.del    "$(del $OWNER_TOKEN)"    200
chk delnobody.editor.upd   "$(upd $EDITOR_TOKEN)"   200
chk delnobody.editor.ins   "$(ins $EDITOR_TOKEN)"   200
rmgrant $G

echo "=== DELETE role:creator + v1 delete + delete-all ==="
curl -s -m 15 -o /dev/null -X POST $V1 -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d '{"Name":"v1a"}'
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_DELETE\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk delrc.editor.v1del "$(v1del $EDITOR_TOKEN)" 403
chk delrc.editor.delall "$(delall $EDITOR_TOKEN)" 403
chk delrc.creator.delall "$(delall $CREATOR_TOKEN)" 200
rmgrant $G

echo "=== VISIBILITY matrix (v2) ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk visrc.editor.vis  "$(vis $EDITOR_TOKEN)"   404
chk visrc.creator.vis "$(vis $CREATOR_TOKEN)"  200
chk visrc.owner.vis   "$(vis $OWNER_TOKEN)"    200
rmgrant $G
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_VISIBILITY\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")
chk visv.editor.vis "$(vis $EDITOR_TOKEN)" 200
chk visv.creator.vis "$(vis $CREATOR_TOKEN)" 200
rmgrant $G

echo "=== v1 insert under ADD nobody (hook via nestedInsert) ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk addnobody.editor.v1ins "$(v1ins $EDITOR_TOKEN)" 403
rmgrant $G

echo "=== grant delete -> next request passes (fail-open after delete) ==="
G=$(mkgrant "{\"entity\":\"table\",\"entity_id\":\"$T\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"nobody\"}")
chk fo.blocked "$(ins $EDITOR_TOKEN)" 403
rmgrant $G
chk fo.opened  "$(ins $EDITOR_TOKEN)" 200

echo "RESULT pass=$PASS fail=$FAIL"
