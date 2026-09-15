#!/bin/bash
# F02 R2 lane2 part 2: fix harness issues, reuse run-3 base
API=http://localhost:8080
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
TMP=/tmp/f02r2l2
PASS=0; FAIL=0; RESULTS=""
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1 (expect $2 got $3)"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (expect $2 got $3)"; fi; }
chkne() { if [ "$2" != "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (unexpected '$3')"; fi; }
code() { local m=$1 u=$2 t=$3 b=$4
  if [ -n "$b" ]; then curl -s -o $TMP/body2 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$b" --max-time 30
  else curl -s -o $TMP/body2 -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" --max-time 30; fi; }
anonym() { curl -s -o $TMP/body2 -w '%{http_code}' -X "$1" "$API$2" -H 'Content-Type: application/json' -d "$3" --max-time 30; }

set -a; . ~/.zcode/.env; set +a
T=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
EV=$(infisical secrets --token "$T" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
export PGPASSWORD=$(grep '^DB_PASSWORD=' <<<"$EV" | cut -d= -f2)
DBU=$(grep '^DB_USER=' <<<"$EV" | cut -d= -f2)
q() { $PSQL -h qnap.elf-balance.ts.net -p 5432 -U "$DBU" -d nocodb-dev -At -c "$1"; }

O=$(cat $TMP/tok-owner)
BID=$(q "SELECT id FROM nc_bases_v2 WHERE title='f02r2l2-base' ORDER BY created_at DESC LIMIT 1")
TID=$(q "SELECT id FROM nc_models_v2 WHERE base_id='$BID' AND title='T1' LIMIT 1")
SECRET_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret' LIMIT 1")
SECRET2_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret2' LIMIT 1")
SECRET3_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret3' LIMIT 1")
SECRET4_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='Secret4' LIMIT 1")
WS=$(q "SELECT fk_workspace_id FROM nc_bases_v2 WHERE id='$BID'")
PHYS=$(q "SELECT table_name FROM nc_models_v2 WHERE id='$TID'")
UIDEB=$(cat $TMP/uid-editorb)
RID=$(q "SELECT id FROM \"$PHYS\" WHERE title='r1' LIMIT 1" 2>/dev/null)
[ -n "$RID" ] || RID=1
echo "BID=$BID TID=$TID SECRET=$SECRET_COL WS=$WS PHYS=$PHYS RID=$RID"

# editorb invite (was 400)
c=$(code POST "/api/v2/meta/bases/$BID/users" "$O" "{\"email\":\"f02r2l2-editorb@test.local\",\"roles\":\"editor\"}")
RES=$(cat $TMP/body2 | head -c 200)
RESULTS="$RESULTS\nINFO invite-editorb: HTTP=$c body=$RES"
# re-signin editorb to refresh token payload if needed
curl -s -X POST "$API/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d '{"email":"f02r2l2-editorb@test.local","password":"Xx123456!"}' | python3 -c 'import sys,json;open("'$TMP'/tok-editorb","w").write(json.load(sys.stdin).get("token",""))'

PERM_URL="/api/v2/meta/bases/$BID/permissions"
TE=$(cat $TMP/tok-editor); TC=$(cat $TMP/tok-creator); TV=$(cat $TMP/tok-viewer); TB=$(cat $TMP/tok-editorb)

# ---- redo matrix with real col id ----
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
chk 'grant role=editor -> 200' 200 "$c"
P1=$(python3 -c 'import json;print(json.load(open("'$TMP'/body2")).get("id",""))')
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk 'duplicate create -> 400 (body:'"$(head -c 80 $TMP/body2)"')' 400 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$O" "[{\"Id\":$RID,\"Secret\":\"m-owner\"}]")
chk 'editor-grant: owner 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret\":\"m-editor\"}]")
chk 'editor-grant: editor 200' 200 "$c"
c=$(code POST "/api/v2/tables/$TID/records" "$TE" "{\"Title\":\"i1x\",\"Secret\":\"nope\"}")
chk 'editor-grant: editor INSERT w/ Secret 403' 403 "$c"
c=$(code DELETE "$PERM_URL/$P1" "$O"); chk 'delete editor-grant' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret\":\"after-del\"}]")
chk 'immediacy after delete: editor 200' 200 "$c"

c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk 'grant role=creator -> 200' 200 "$c"
P2=$(python3 -c 'import json;print(json.load(open("'$TMP'/body2")).get("id",""))')
c=$(code PATCH "/api/v2/tables/$TID/records" "$TC" "[{\"Id\":$RID,\"Secret\":\"c-creator\"}]")
chk 'creator-grant: creator 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret\":\"c-editor\"}]")
chk 'creator-grant: editor 403' 403 "$c"
c=$(code DELETE "$PERM_URL/$P2" "$O"); chk 'cleanup creator-grant' 200 "$c"

# ---- R1: user grant + nobody transition ----
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$UIDEB\"}]}")
chk 'user grant w/ subject -> 200' 200 "$c"
P3=$(python3 -c 'import json;print(json.load(open("'$TMP'/body2")).get("id",""))')
c=$(code PATCH "/api/v2/tables/$TID/records" "$TB" "[{\"Id\":$RID,\"Secret\":\"u-editorb\"}]")
chk 'user-grant: subject editorb 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret\":\"u-editor\"}]")
chk 'user-grant: non-subject editor 403' 403 "$c"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"user","subjects":[]}')
chk 'empty subjects update -> 400' 400 "$c"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"nobody"}')
chk 'nobody transition -> 200' 200 "$c"
DB_GR=$(q "SELECT coalesce(granted_role,'<null>') FROM nc_permissions WHERE id='$P3'")
DB_SUBJ=$(q "SELECT count(*) FROM nc_permission_subjects WHERE fk_permission_id='$P3'")
chk 'nobody clears granted_role (DB)' '<null>' "$DB_GR"
chk 'nobody clears subjects (DB)' '0' "$DB_SUBJ"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"user"}')
STALE=$(q "SELECT count(*) FROM nc_permission_subjects WHERE fk_permission_id='$P3'")
RESULTS="$RESULTS\nINFO nobody->user switch no-subjects: HTTP=$c stale_subject_rows=$STALE (403=succeeded via stale subjects)"
c=$(code DELETE "$PERM_URL/$P3" "$O"); chk 'cleanup user-grant' 200 "$c"

# ---- multi-grant via direct DB ----
mkperm() { local pid="r2l2b$(date +%s%N | tail -c 12)"; local col=$1 ty=$2 role=$3 subj=$4
  q "INSERT INTO nc_permissions (id,fk_workspace_id,base_id,entity,entity_id,permission,enforce_for_form,enforce_for_automation,granted_type,granted_role) VALUES ('$pid','$WS','$BID','field','$col','RECORD_FIELD_EDIT',true,true,'$ty',$( [ -n "$role" ] && echo "'$role'" || echo "NULL" ))" >/dev/null
  if [ -n "$subj" ]; then q "INSERT INTO nc_permission_subjects (fk_permission_id,subject_type,subject_id,fk_workspace_id,base_id) VALUES ('$pid','user','$subj','$WS','$BID')" >/dev/null; fi
  echo "$pid"; }
A1=$(mkperm "$SECRET2_COL" role creator ''); A2=$(mkperm "$SECRET2_COL" role editor '')
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret2\":\"mg-e\"}]")
chk 'multi [creator,editor]: editor 403 (any-deny)' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TC" "[{\"Id\":$RID,\"Secret2\":\"mg-c\"}]")
chk 'multi [creator,editor]: creator 200' 200 "$c"
B1=$(mkperm "$SECRET3_COL" role editor ''); B2=$(mkperm "$SECRET3_COL" role creator '')
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret3\":\"mg2-e\"}]")
chk 'multi reversed order: editor 403' 403 "$c"
C1=$(mkperm "$SECRET4_COL" role editor ''); C2=$(mkperm "$SECRET4_COL" user '' "$UIDEB")
c=$(code PATCH "/api/v2/tables/$TID/records" "$TE" "[{\"Id\":$RID,\"Secret4\":\"ru-e\"}]")
chk 'multi role+user: editor(non-subject) 403' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$TB" "[{\"Id\":$RID,\"Secret4\":\"ru-eb\"}]")
chk 'multi role+user: subject editorb 200' 200 "$c"
for p in $A1 $A2 $B1 $B2 $C1 $C2; do q "DELETE FROM nc_permission_subjects WHERE fk_permission_id='$p';DELETE FROM nc_permissions WHERE id='$p';" >/dev/null; done

# ---- v1 classic insert (dataAlias) ----
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
P4=$(python3 -c 'import json;print(json.load(open("'$TMP'/body2")).get("id",""))')
chk 're-grant role=editor' 200 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/T1" "$TE" '{"Title":"v1e","Secret":"v1s"}')
chk 'v1 insert restricted (editor) 403' 403 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/T1" "$TE" '{"Title":"v1ok"}')
chk 'v1 insert w/o restricted (editor) 200' 200 "$c"
c=$(code POST "/api/v1/db/data/v1/$BID/T1" "$O" '{"Title":"v1o","Secret":"v1os"}')
chk 'v1 insert restricted (owner) 200' 200 "$c"

# ---- public/shared form ----
c=$(code POST "/api/v2/meta/tables/$TID/forms" "$O" '{"title":"F2"}')
FVID=$(python3 -c 'import json;print(json.load(open("'$TMP'/body2")).get("id",""))')
c=$(code PATCH "/api/v2/meta/views/$FVID" "$O" '{"shared":true}')
SHARE_RES=$(cat $TMP/body2)
UUID=$(python3 -c 'import json;d=json.load(open("'$TMP'/body2"));print(d.get("uuid",""))' 2>/dev/null)
if [ -z "$UUID" ]; then UUID=$(echo "$SHARE_RES" | python3 -c 'import sys,json,re;s=sys.stdin.read();m=re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",s);print(m.group(0) if m else "")' 2>/dev/null); fi
RESULTS="$RESULTS\nINFO share-res: $(echo $SHARE_RES | head -c 160)"
chkne 'form share uuid' '' "$UUID"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon1","Secret":"leak"}}')
chk 'anon form restricted -> 403 (enforce_for_form)' 403 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon2"}}')
chk 'anon form w/o restricted -> 200' 200 "$c"
q "UPDATE nc_permissions SET enforce_for_form=false WHERE id='$P4'" >/dev/null
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon3","Secret":"optout"}}')
chk 'anon form enforce_for_form=false -> 200' 200 "$c"
LANDED=$(q "SELECT count(*) FROM \"$PHYS\" WHERE title='anon3' AND secret='optout'")
chk 'anon opt-out value landed' 1 "$LANDED"
q "UPDATE nc_permissions SET enforce_for_form=true WHERE id='$P4'" >/dev/null
# editor-authenticated form-context write (datas view path flagged isPublicForm)
c=$(code PATCH "/api/v2/tables/$TID/records" "$TV" "[{\"Id\":$RID,\"Secret\":\"tv\"}]")
chk 'viewer PATCH still 403' 403 "$c"
c=$(code DELETE "$PERM_URL/$P4" "$O"); chk 'cleanup P4' 200 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon4","Secret":"postdel"}}')
chk 'anon form after grant delete -> 200 (fail-open)' 200 "$c"

echo -e "$RESULTS" > /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/r2-f02-lane2-out2.txt
echo "== PASS=$PASS FAIL=$FAIL =="
echo -e "$RESULTS"
