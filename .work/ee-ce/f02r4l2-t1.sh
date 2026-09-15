#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
SC=$F02R4L2_SECRET_COL
req() { # method path body -> "http_code body"
  local m=$1 p=$2 body=$3
  local out
  out=$(curl -s -w $'\n%{http_code}' -X $m "$B$p" -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' ${body:+-d "$body"})
  echo "$out" | /usr/bin/python3 -c 'import sys;d=sys.stdin.read().split("\n");print(d[-1], " ".join(d[:-1])[:160])'
}
grant_state() {
  $DBQ "select granted_type, coalesce(granted_role,'-'), (select count(*) from nc_permission_subjects s where s.fk_permission_id=p.id) from nc_permissions p where p.entity_id='$SC';"
}

echo "=== T1: R3 fix core (Secret col) ==="
echo "-- 1.1 create nobody grant"
req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"
PID=$($DBQ "select id from nc_permissions where entity_id='$SC' limit 1;")
echo "PID=$PID"; grant_state

echo "-- 1.2 PATCH nobody+subjects (R3 core: expect 400)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"nobody\",\"subjects\":[{\"type\":\"user\",\"id\":\"$F02R4L2_EID\"}]}"
echo "   state after: $(grant_state)"

echo "-- 1.3 PATCH user without subjects (bypass chain closure: expect 400)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"user\"}"
echo "   state after: $(grant_state)"

echo "-- 1.4 PATCH role without granted_role (expect 400)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"role\"}"
echo "   state after: $(grant_state)"

echo "-- 1.5 PATCH role+creator (expect 200)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"role\",\"granted_role\":\"creator\"}"
echo "   state after: $(grant_state)"

echo "-- 1.6 PATCH nobody+subjects EMPTY array (expect 200, subjects stay 0)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{\"granted_type\":\"nobody\",\"subjects\":[]}"
echo "   state after: $(grant_state)"

echo "-- 1.7 PATCH empty payload {} (expect 200 no-op)"
req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "{}"
echo "   state after: $(grant_state)"
