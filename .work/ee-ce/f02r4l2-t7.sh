#!/bin/zsh
set -a; . /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.f02r4l2-tokens; set +a
DBQ=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l2-dbq.sh
B=http://localhost:8080
SC=$F02R4L2_SECRET_COL
req() { curl -s -o /tmp/f02r4l2-last -w '%{http_code}' -X $1 "$B$2" -H "xc-auth: ${3:-$F02R4L2_TOK}" -H 'Content-Type: application/json' ${4:+-d "$4"}; }
echo "=== T7 ==="
echo "7.1 create user grant without subjects -> $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "" "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\"}")"
echo "7.2 create duplicate -> first:"
curl -s -o /dev/null -X POST $B/api/v2/meta/bases/$F02R4L2_BASE/permissions -H "xc-auth: $F02R4L2_TOK" -H 'Content-Type: application/json' -d "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}"
PID=$($DBQ "select id from nc_permissions where entity_id='$SC' limit 1;")
echo "   second -> $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "" "{\"entity\":\"field\",\"entity_id\":\"$SC\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"nobody\"}")"
echo "7.3 nobody row PATCH {nobody, granted_role:creator} -> $(req PATCH /api/v2/meta/bases/$F02R4L2_BASE/permissions/$PID "" '{"granted_type":"nobody","granted_role":"creator"}')  state=$($DBQ "select granted_type||'|'||coalesce(granted_role,'<NULL>') from nc_permissions where id='$PID';")"
echo "7.4 create team subject -> $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "" "{\"entity\":\"field\",\"entity_id\":\"$F02R4L2_TITLE_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"team\",\"id\":\"t1\"}]}")"
echo "7.5 v1 path list -> $(req GET /api/v1/db/meta/bases/$F02R4L2_BASE/permissions "")"
echo "7.6 v1 path update -> $(req PATCH /api/v1/db/meta/bases/$F02R4L2_BASE/permissions/$PID "" '{"granted_type":"nobody"}')"
echo "7.7 invalid granted_role on create -> $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "" "{\"entity\":\"field\",\"entity_id\":\"$F02R4L2_AMOUNT_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"superuser\"}")"
echo "7.8 granted_role below minimum (viewer for RECORD_FIELD_EDIT) -> $(req POST /api/v2/meta/bases/$F02R4L2_BASE/permissions "" "{\"entity\":\"field\",\"entity_id\":\"$F02R4L2_AMOUNT_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")"
$DBQ "delete from nc_permission_subjects where fk_permission_id in (select id from nc_permissions where base_id='$F02R4L2_BASE');" >/dev/null
$DBQ "delete from nc_permissions where base_id='$F02R4L2_BASE';" >/dev/null
echo "cleanup done: $($DBQ "select count(*) from nc_permissions where base_id='$F02R4L2_BASE';")"
