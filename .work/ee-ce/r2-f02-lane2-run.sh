#!/bin/bash
# F02 R2 lane2 integration tests (self-contained, bash-3.2 safe)
API=http://localhost:8080
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
TMP=/tmp/f02r2l2
PASS=0; FAIL=0; RESULTS=""
mkdir -p $TMP

set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
DBENV=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_HOST=qnap.elf-balance.ts.net   # Infisical value 'pg18' unresolvable off-QNap (AGENTS.md §3.1)
DB_PORT=$(echo "$DBENV" | grep '^DB_PORT=' | cut -d= -f2)
DB_USER=$(echo "$DBENV" | grep '^DB_USER=' | cut -d= -f2)
DB_PASSWORD=$(echo "$DBENV" | grep '^DB_PASSWORD=' | cut -d= -f2)
DB_NAME=nocodb-dev
export PGPASSWORD="$DB_PASSWORD"
q() { $PSQL -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -At -c "$1"; }
echo "db-check: $(q 'select 1')"

chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1 (expect $2 got $3)"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (expect $2 got $3)"; fi; }
chkne() { if [ "$2" != "$3" ]; then PASS=$((PASS+1)); RESULTS="$RESULTS\nPASS $1 (got non-empty)"; else FAIL=$((FAIL+1)); RESULTS="$RESULTS\nFAIL $1 (unexpected '$3')"; fi; }

code() { local m=$1 u=$2 t=$3 b=$4
  if [ -n "$b" ]; then curl -s -o $TMP/body -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$b" --max-time 30
  else curl -s -o $TMP/body -w '%{http_code}' -X "$m" "$API$u" -H "xc-auth: $t" --max-time 30; fi; }
anonym() { local m=$1 u=$2 b=$3
  if [ -n "$b" ]; then curl -s -o $TMP/body -w '%{http_code}' -X "$m" "$API$u" -H 'Content-Type: application/json' -d "$b" --max-time 30
  else curl -s -o $TMP/body -w '%{http_code}' -X "$m" "$API$u" --max-time 30; fi; }

# ---------- users ----------
PW='Xx123456!'
for r in owner creator editor editorb commenter viewer; do
  E="f02r2l2-$r@test.local"
  curl -s -X POST "$API/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$PW\"}" >/dev/null
  if [ "$r" = owner ]; then q "UPDATE nc_users_v2 SET roles='super' WHERE email='$E'" >/dev/null; fi
  curl -s -X POST "$API/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$PW\"}" \
    | python3 -c 'import sys,json;open("'$TMP'/tok-'$r'","w").write(json.load(sys.stdin).get("token",""))' 2>/dev/null
  q "SELECT id FROM nc_users_v2 WHERE email='$E'" > $TMP/uid-$r
done
O=$(cat $TMP/tok-owner)
chkne 'token owner' '' "$O"
chkne 'token editor' '' "$(cat $TMP/tok-editor)"
chkne 'token editorb' '' "$(cat $TMP/tok-editorb)"
chkne 'uid editorb' '' "$(cat $TMP/uid-editorb)"

# ---------- base & table ----------
code POST /api/v2/meta/bases "$O" '{"title":"f02r2l2-base"}' >/dev/null
BID=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
chkne 'create base' '' "$BID"
code POST "/api/v2/meta/bases/$BID/tables" "$O" '{"table_name":"T1","columns":[{"column_name":"Title","uidt":"SingleLineText"},{"column_name":"Secret","uidt":"SingleLineText"},{"column_name":"Secret2","uidt":"SingleLineText"},{"column_name":"Secret3","uidt":"SingleLineText"},{"column_name":"Secret4","uidt":"SingleLineText"}]}' >/dev/null
TID=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
chkne 'create table' '' "$TID"
SECRET_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='secret' LIMIT 1")
SECRET2_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='secret2' LIMIT 1")
SECRET3_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='secret3' LIMIT 1")
SECRET4_COL=$(q "SELECT id FROM nc_columns_v2 WHERE fk_model_id='$TID' AND column_name='secret4' LIMIT 1")
chkne 'find Secret col' '' "$SECRET_COL"
WS=$(q "SELECT fk_workspace_id FROM nc_bases_v2 WHERE id='$BID'")
code POST "/api/v2/tables/$TID/records" "$O" '{"Title":"r1"}' >/dev/null
RID=$(python3 -c 'import json;d=json.load(open("'$TMP'/body"));print((d[0] if isinstance(d,list) else d).get("Id",""))')
chkne 'insert row' '' "$RID"

for r in creator editor editorb commenter viewer; do
  c=$(code POST "/api/v2/meta/bases/$BID/users" "$O" "{\"email\":\"f02r2l2-$r@test.local\",\"roles\":\"$r\"}")
  chk "invite $r" 200 "$c"
done
sleep 1
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Title\":\"e0\"}]")
chk 'baseline editor PATCH no-grant' 200 "$c"

PERM_URL="/api/v2/meta/bases/$BID/permissions"

# ---------- TEST 1: role matrix ----------
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"viewer\"}")
chk 'matrix: grant role=viewer -> 400' 400 "$c"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"commenter\"}")
chk 'matrix: grant role=commenter -> 400' 400 "$c"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
chk 'matrix: grant role=editor -> 200' 200 "$c"
P1=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk 'R1: duplicate create -> 400' 400 "$c"

c=$(code PATCH "/api/v2/tables/$TID/records" "$O" "[{\"Id\":$RID,\"Secret\":\"m-owner\"}]")
chk 'matrix editor-grant: owner 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-creator)" "[{\"Id\":$RID,\"Secret\":\"m-creator\"}]")
chk 'matrix editor-grant: creator 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret\":\"m-editor\"}]")
chk 'matrix editor-grant: editor 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-commenter)" "[{\"Id\":$RID,\"Secret\":\"m-commenter\"}]")
chk 'matrix editor-grant: commenter 403' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-viewer)" "[{\"Id\":$RID,\"Secret\":\"m-viewer\"}]")
chk 'matrix editor-grant: viewer 403' 403 "$c"
c=$(code POST "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "{\"Title\":\"i1\",\"Secret\":\"nope\"}")
chk 'matrix editor-grant: editor INSERT w/ Secret 403' 403 "$c"
c=$(code POST "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" '{"Title":"i2"}')
chk 'matrix editor-grant: editor INSERT w/o Secret 200' 200 "$c"

c=$(code DELETE "$PERM_URL/$P1" "$O"); chk 'delete editor-grant' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret\":\"after-del\"}]")
chk 'immediacy: after delete editor PATCH 200' 200 "$c"

c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"creator\"}")
chk 'grant role=creator -> 200' 200 "$c"
P2=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
c=$(code PATCH "/api/v2/tables/$TID/records" "$O" "[{\"Id\":$RID,\"Secret\":\"c-owner\"}]")
chk 'matrix creator-grant: owner 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-creator)" "[{\"Id\":$RID,\"Secret\":\"c-creator\"}]")
chk 'matrix creator-grant: creator 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret\":\"c-editor\"}]")
chk 'matrix creator-grant: editor 403' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-viewer)" "[{\"Id\":$RID,\"Secret\":\"c-viewer\"}]")
chk 'matrix creator-grant: viewer 403' 403 "$c"
c=$(code DELETE "$PERM_URL/$P2" "$O"); chk 'cleanup creator-grant' 200 "$c"

# ---------- TEST 2: R1 fixes ----------
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[]}")
chk 'R1: user grant empty subjects create -> 400' 400 "$c"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\"}")
chk 'R1: user grant no subjects create -> 400' 400 "$c"
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"user\",\"subjects\":[{\"type\":\"user\",\"id\":\"$(cat $TMP/uid-editorb)\"}]}")
chk 'R1: user grant w/ subject -> 200' 200 "$c"
P3=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editorb)" "[{\"Id\":$RID,\"Secret\":\"u-editorb\"}]")
chk 'R1 user-grant: subject editorb 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret\":\"u-editor\"}]")
chk 'R1 user-grant: non-subject editor 403' 403 "$c"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"user","subjects":[]}')
chk 'R1: empty subjects update -> 400' 400 "$c"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"nobody"}')
chk 'R1: nobody transition -> 200' 200 "$c"
DB_GR=$(q "SELECT coalesce(granted_role,'<null>') FROM nc_permissions WHERE id='$P3'")
DB_SUBJ=$(q "SELECT count(*) FROM nc_permission_subjects WHERE fk_permission_id='$P3'")
chk 'R1: nobody clears granted_role (DB)' '<null>' "$DB_GR"
chk 'R1: nobody clears subjects (DB)' '0' "$DB_SUBJ"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editorb)" "[{\"Id\":$RID,\"Secret\":\"n-editorb\"}]")
chk 'R1: nobody denies subject (immediacy)' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$O" "[{\"Id\":$RID,\"Secret\":\"n-owner\"}]")
chk 'R1: nobody bypasses owner' 200 "$c"
c=$(code PATCH "$PERM_URL/$P3" "$O" '{"granted_type":"user"}')
STALE=$(q "SELECT count(*) FROM nc_permission_subjects WHERE fk_permission_id='$P3'")
RESULTS="$RESULTS\nINFO nobody->user switch no-subjects: HTTP=$c stale_subject_rows=$STALE"
c=$(code DELETE "$PERM_URL/$P3" "$O"); chk 'cleanup user-grant' 200 "$c"

c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"table\",\"entity_id\":\"$TID\",\"permission\":\"TABLE_RECORD_ADD\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
chk 'R1: table-entity create -> 400' 400 "$c"

# multi-grant via direct DB
mkperm() { local pid="r2l2$(date +%s%N | tail -c 13)"; local col=$1 ty=$2 role=$3 subj=$4
  q "INSERT INTO nc_permissions (id,fk_workspace_id,base_id,entity,entity_id,permission,enforce_for_form,enforce_for_automation,granted_type,granted_role) VALUES ('$pid','$WS','$BID','field','$col','RECORD_FIELD_EDIT',true,true,'$ty',$( [ -n "$role" ] && echo "'$role'" || echo "NULL" ))" >/dev/null
  if [ -n "$subj" ]; then q "INSERT INTO nc_permission_subjects (fk_permission_id,subject_type,subject_id,fk_workspace_id,base_id) VALUES ('$pid','user','$subj','$WS','$BID')" >/dev/null; fi
  echo "$pid"; }
A1=$(mkperm "$SECRET2_COL" role creator '')
A2=$(mkperm "$SECRET2_COL" role editor '')
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret2\":\"mg-e\"}]")
chk 'multi-grant [creator,editor]: editor 403 (any-deny)' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-creator)" "[{\"Id\":$RID,\"Secret2\":\"mg-c\"}]")
chk 'multi-grant [creator,editor]: creator 200' 200 "$c"
B1=$(mkperm "$SECRET3_COL" role editor '')
B2=$(mkperm "$SECRET3_COL" role creator '')
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret3\":\"mg2-e\"}]")
chk 'multi-grant reversed order: editor 403' 403 "$c"
C1=$(mkperm "$SECRET4_COL" role editor '')
C2=$(mkperm "$SECRET4_COL" user '' "$(cat $TMP/uid-editorb)")
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editor)" "[{\"Id\":$RID,\"Secret4\":\"ru-e\"}]")
chk 'multi-grant role+user: editor(non-subject) 403' 403 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-editorb)" "[{\"Id\":$RID,\"Secret4\":\"ru-eb\"}]")
chk 'multi-grant role+user: subject editorb 200' 200 "$c"
c=$(code PATCH "/api/v2/tables/$TID/records" "$O" "[{\"Id\":$RID,\"Secret4\":\"ru-o\"}]")
chk 'multi-grant role+user: owner 200' 200 "$c"
for p in $A1 $A2 $B1 $B2 $C1 $C2; do q "DELETE FROM nc_permission_subjects WHERE fk_permission_id='$p';DELETE FROM nc_permissions WHERE id='$p';" >/dev/null; done

# ---------- TEST 3: nestedInsert / v1 / public form ----------
c=$(code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"$SECRET_COL\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}")
P4=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
chk 're-grant role=editor for v1/form' 200 "$c"
BNAME=$(q "SELECT title FROM nc_bases_v2 WHERE id='$BID'")
c=$(code POST "/api/v1/db/data/v1/$WS/$BNAME/T1" "$(cat $TMP/tok-editor)" '{"Title":"v1e","Secret":"v1s"}')
chk 'v1 classic insert restricted (editor) 403' 403 "$c"
c=$(code POST "/api/v1/db/data/v1/$WS/$BNAME/T1" "$(cat $TMP/tok-editor)" '{"Title":"v1ok"}')
chk 'v1 classic insert w/o restricted (editor) 200' 200 "$c"
c=$(code POST "/api/v1/db/data/v1/$WS/$BNAME/T1" "$O" '{"Title":"v1o","Secret":"v1os"}')
chk 'v1 classic insert restricted (owner) 200' 200 "$c"
c=$(code POST "/api/v1/db/data/$TID/" "$(cat $TMP/tok-editor)" '{"Title":"v1ve","Secret":"x"}')
chk 'v1 view-path insert restricted (editor) 403' 403 "$c"

c=$(code POST "/api/v2/meta/tables/$TID/forms" "$O" '{"title":"F"}')
FVID=$(python3 -c 'import json;print(json.load(open("'$TMP'/body")).get("id",""))')
chkne 'create form view' '' "$FVID"
c=$(code PATCH "/api/v2/meta/views/$FVID" "$O" '{"shared":true}')
UUID=$(python3 -c 'import json;d=json.load(open("'$TMP'/body"));print((d.get("shared_view") or d).get("uuid") or d.get("uuid","") if isinstance(d,dict) else "")')
chkne 'share form view (uuid)' '' "$UUID"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon1","Secret":"leak"}}')
chk 'anon form restricted field -> 403 (enforce_for_form)' 403 "$c"
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon2"}}')
chk 'anon form w/o restricted field -> 200' 200 "$c"
q "UPDATE nc_permissions SET enforce_for_form=false WHERE id='$P4'" >/dev/null
c=$(anonym POST "/api/v2/public/shared-view/$UUID/rows" '{"data":{"Title":"anon3","Secret":"optout"}}')
chk 'anon form enforce_for_form=false -> 200' 200 "$c"
LANDED=$(q "SELECT count(*) FROM "$(q "SELECT table_name FROM nc_models_v2 WHERE id='$TID'")" WHERE title='anon3' AND secret='optout'")
chk 'anon opt-out value landed' 1 "$LANDED"
q "UPDATE nc_permissions SET enforce_for_form=true WHERE id='$P4'" >/dev/null
c=$(code DELETE "$PERM_URL/$P4" "$O"); chk 'cleanup P4' 200 "$c"

# ---------- error message capture ----------
code POST "$PERM_URL" "$O" "{\"entity\":\"field\",\"entity_id\":\"nonexistent\",\"permission\":\"RECORD_FIELD_EDIT\",\"granted_type\":\"role\",\"granted_role\":\"editor\"}" >/dev/null
MSG1=$(cat $TMP/body)
code PATCH "/api/v2/tables/$TID/records" "$(cat $TMP/tok-viewer)" "[{\"Id\":$RID,\"Secret\":\"msg\"}]" >/dev/null
MSG2=$(cat $TMP/body)
RESULTS="$RESULTS\nINFO errbody-invalid-col: $MSG1\nINFO errbody-403: $MSG2"

echo -e "$RESULTS" > /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/r2-f02-lane2-out.txt
echo "== PASS=$PASS FAIL=$FAIL =="
echo -e "$RESULTS"
