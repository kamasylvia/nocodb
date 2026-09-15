#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/r5l1-state.env"
. "$D/r5l1-common.sh"
B=http://localhost:8080
P="$B/api/v2/meta/bases/$BID/permissions"
J="$D/r5l1-tmp.json"
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
export PGPASSWORD="$DB_PASSWORD"
EUID_=$("$PSQL" -h qnap.elf-balance.ts.net -p "$DB_PORT" -U "$DB_USER" -d "$DEVDB" -t -A -c "SELECT id FROM nc_users_v2 WHERE email='$E'")
CUID=$("$PSQL" -h qnap.elf-balance.ts.net -p "$DB_PORT" -U "$DB_USER" -d "$DEVDB" -t -A -c "SELECT id FROM nc_users_v2 WHERE email='$C'")
PK="RECORD_FIELD_EDIT"
V1TAB="$B/api/v1/db/data/noco/$BID/$TID"
PASS=0; FAIL=0
chk() { local label="$1" got="$2" exp="$3"; if [ "$got" = "$exp" ]; then PASS=$((PASS+1)); echo "  ok   $label -> $got"; else FAIL=$((FAIL+1)); echo "  FAIL $label -> $got (expect $exp)"; fi }

setgrant() { # setgrant <json>
  local gid; gid=$(curl -s "$P" -H "xc-auth: $TO" | jq -r --arg c "$SECRET_ID" '.[] | select(.entity_id==$c) | .id')
  if [ -n "$gid" ]; then curl -s -o /dev/null -X DELETE "$P/$gid" -H "xc-auth: $TO"; fi
  curl -s -o "$J" -X POST "$P" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "$1"
}

patch() { curl -s -o "$J" -w "%{http_code}" -X PATCH "$B/api/v2/tables/$TID/records" -H "xc-auth: $1" -H 'Content-Type: application/json' -d "{\"Id\":\"$RID\",\"Secret\":\"$2\"}"; }
ins() { curl -s -o "$J" -w "%{http_code}" -X POST "$B/api/v2/tables/$TID/records" -H "xc-auth: $1" -H 'Content-Type: application/json' -d "{\"Name\":\"$2\",\"Secret\":\"$2-s\"}"; }
bulkins() { curl -s -o "$J" -w "%{http_code}" -X POST "$B/api/v1/db/data/bulk/noco/$BID/$TID" -H "xc-auth: $1" -H 'Content-Type: application/json' -d "[{\"Name\":\"$2\",\"Secret\":\"$2-s\"}]"; }
v1ins() { curl -s -o "$J" -w "%{http_code}" -X POST "$V1TAB" -H "xc-auth: $1" -H 'Content-Type: application/json' -d "{\"Name\":\"$2\",\"Secret\":\"$2-s\"}"; }

echo "== G1 nobody =="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\"}"
chk "immediacy ed PATCH" "$(patch "$TE" imm1)" 403
chk "ed PATCH"     "$(patch "$TE" t1)" 403
chk "cr PATCH"     "$(patch "$TC" t1)" 403
chk "ow PATCH"     "$(patch "$TO" t1ok)" 200
chk "ed insert"    "$(ins "$TE" nobody_ed)" 403
chk "cr insert"    "$(ins "$TC" nobody_cr)" 403
chk "ow insert"    "$(ins "$TO" nobody_ow)" 200
chk "ed bulk"      "$(bulkins "$TE" nobody_b)" 403
chk "ow bulk"      "$(bulkins "$TO" nobody_bow)" 200
chk "ed v1 insert" "$(v1ins "$TE" nobody_v1)" 403
chk "cr v1 insert" "$(v1ins "$TC" nobody_v1c)" 403
chk "ow v1 insert" "$(v1ins "$TO" nobody_v1o)" 200

echo "== G2 role:editor =="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}"
chk "immediacy ed PATCH" "$(patch "$TE" imm2)" 200
chk "ed PATCH"  "$(patch "$TE" t2)" 200
chk "cr PATCH"  "$(patch "$TC" t2)" 200
chk "ed insert" "$(ins "$TE" red_ed)" 200
chk "ed v1 ins" "$(v1ins "$TE" red_v1)" 200

echo "== G3 role:creator =="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}"
chk "immediacy ed PATCH" "$(patch "$TE" imm3)" 403
chk "ed PATCH"  "$(patch "$TE" t3)" 403
chk "cr PATCH"  "$(patch "$TC" t3)" 200
chk "ow PATCH"  "$(patch "$TO" t3ok)" 200
chk "ed bulk"   "$(bulkins "$TE" rc_b)" 403
chk "cr bulk"   "$(bulkins "$TC" rc_bc)" 200
chk "ed v1"     "$(v1ins "$TE" rc_v1)" 403

echo "== G4 user:[editor] =="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$EUID_\"}]}"
chk "immediacy ed PATCH" "$(patch "$TE" imm4)" 200
chk "ed PATCH"  "$(patch "$TE" t4)" 200
chk "cr PATCH"  "$(patch "$TC" t4)" 403
chk "ow PATCH"  "$(patch "$TO" t4ok)" 200
chk "ed insert" "$(ins "$TE" ug_ed)" 200
chk "cr insert" "$(ins "$TC" ug_cr)" 403

echo "== G5 user:[creator]（跨角色：creator 在名单内，editor 不在）=="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$CUID\"}]}"
chk "ed PATCH"  "$(patch "$TE" t5)" 403
chk "cr PATCH"  "$(patch "$TC" t5)" 200

echo "== G6 删除 grant → fail-open 恢复 =="
gid=$(curl -s "$P" -H "xc-auth: $TO" | jq -r --arg c "$SECRET_ID" '.[] | select(.entity_id==$c) | .id')
curl -s -o /dev/null -X DELETE "$P/$gid" -H "xc-auth: $TO"
chk "ed PATCH after delete" "$(patch "$TE" t6)" 200

echo "== G7 enforce_for_form=false 不影响数据路由 =="
setgrant "{\"entity\":\"field\",\"entity_id\":\"$SECRET_ID\",\"permission\":\"$PK\",\"granted_type\":\"nobody\",\"enforce_for_form\":false}"
chk "ed PATCH (form opt-out does not lift data deny)" "$(patch "$TE" t7)" 403

echo "== 清场：删 grant 恢复默认 =="
gid=$(curl -s "$P" -H "xc-auth: $TO" | jq -r --arg c "$SECRET_ID" '.[] | select(.entity_id==$c) | .id')
[ -n "$gid" ] && curl -s -o /dev/null -X DELETE "$P/$gid" -H "xc-auth: $TO"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
