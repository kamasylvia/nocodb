#!/bin/zsh
# f07r3b_run.sh — F07 Snapshots R3 对抗收敛确认 (第2路 集成测试-对抗面)
# 目标库: nocodb-dev ONLY (qnap.elf-balance.ts.net). 后端 http://127.0.0.1:8080 (勿重启).
set -u
API=http://127.0.0.1:8080
REPO=/Volumes/UNITEK/Documents/Development/nocodb
W=$REPO/.work/ee-ce
LOG=$W/f07r3b_results.txt
: > "$LOG"

log() { print -r -- "$1" >> "$LOG"; }
sec() { log ""; log "== $1 =="; }
chk() { # name expected actual
  if [ "$2" = "$3" ]; then log "PASS ${1} (=${3})"; else log "FAIL ${1} expected=[${2}] got=[${3}]"; fi
}
chkin() { # name needle actual  (substring match)
  case "$3" in *"$2"*) log "PASS ${1} (contains [$2])";; *) log "FAIL ${1} expected to contain [$2] got=[${3}]";; esac
}

# ---------- DB env (Infisical KDL → nocodb-dev ONLY) ----------
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
ITOK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
eval $(infisical secrets --token "$ITOK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^DB_(HOST|PORT|USER|PASSWORD)=' | sed 's/^/export /')
export FDB_HOST=qnap.elf-balance.ts.net FDB_PORT="${DB_PORT:-5432}" FDB_USER="$DB_USER" FDB_PASSWORD="$DB_PASSWORD"
dbq() { uv run --with pg8000 python3 "$W/f05r3b_dbq.py" "$1" ${2:-}; }

# ---------- tokens ----------
TOKEN_B=$(cat "$W/f07r3b_tokB")   # f07r3b — primary (creator of test bases)
TOKEN_A=$(cat "$W/f07r3b_tokA")   # f01e2e — second account (permission matrix)
[ -n "$TOKEN_B" ] && [ -n "$TOKEN_A" ] || { log "FATAL tokens missing"; exit 1; }

# ensure f07r3b is workspace-level-creator in Default Workspace (signup lands as no-access)
WSID=$(dbq "select fk_workspace_id as w from workspace_user wu join nc_users_v2 u on u.id=wu.fk_user_id where u.email='f07r3b@ce-ee.local' limit 1" --one | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("w",""))' 2>/dev/null)
log "workspace: ${WSID:-NONE}"
WSUID=$(api PATCH "/api/v1/workspaces/$WSID/users/$(dbq "select id as i from nc_users_v2 where email='f07r3b@ce-ee.local' limit 1" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["i"])' 2>/dev/null)" "$TOKEN_A" '{"roles":"workspace-level-creator"}')
log "  promote f07r3b -> creator: $(code "$WSUID") $(body "$WSUID" | head -c 150)"

signin_a() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null; }
signin_b() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f07r3b@ce-ee.local","password":"F07r3b!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null; }

api() { # method path token [data] -> CODE:body
  local m=$1 p=$2 t=$3 d=${4:-} tf=/tmp/f07r3b_last.json
  if [ -n "$d" ]; then
    CODE=$(curl -s -m 30 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d")
  else
    CODE=$(curl -s -m 30 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t")
  fi
  # dev JWTs expire fast — auto-refresh and retry once on 401
  if [ "$CODE" = "401" ]; then
    if [ "$t" = "$TOKEN_B" ]; then local NT=$(signin_b); [ -n "$NT" ] && { TOKEN_B="$NT"; t="$NT"; printf '%s' "$NT" > "$W/f07r3b_tokB"; };
    else local NT=$(signin_a); [ -n "$NT" ] && { TOKEN_A="$NT"; t="$NT"; printf '%s' "$NT" > "$W/f07r3b_tokA"; }; fi
    if [ -n "$d" ]; then
      CODE=$(curl -s -m 30 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d")
    else
      CODE=$(curl -s -m 30 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t")
    fi
  fi
  print -r -- "CODE:${CODE}|$(cat "$tf" | head -c 1500)"
}
code() { print -r -- "${1%%|*}" | sed 's/CODE://'; }
body() { print -r -- "${1#*|}"; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

# ---------- wait backend ----------
for i in $(seq 1 30); do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API/api/v2/meta/bases" -H "xc-auth: $TOKEN_B" 2>/dev/null)
  [ "$C" != "000" ] && [ -n "$C" ] && [ "$C" != "401" ] && break
  sleep 2
done

CLEAN_BASES=()

# ============ Setup: bases ============
sec "SETUP"
R=$(api POST /api/v2/meta/bases "$TOKEN_B" '{"title":"f07r3b_src"}')
SRC=$(body "$R" | jget "['id']")
chk "setup.create_src_base" 200 "$(code "$R")"
log "  src base id: $SRC"
CLEAN_BASES+=("$SRC")

R=$(api POST /api/v2/meta/bases "$TOKEN_B" '{"title":"f07r3b_xbase"}')
XBASE=$(body "$R" | jget "['id']")
chk "setup.create_xbase" 200 "$(code "$R")"
CLEAN_BASES+=("$XBASE")

# ============ T1: illegal input matrix ============
sec "T1 illegal-input matrix (create title / non-existent ids / cross-base)"

R=$(api POST "/api/v2/meta/bases/$SRC/snapshots" "$TOKEN_B" '{"title":12345}')
chk "T1.1 create title=number -> 400" 400 "$(code "$R")"
chkin "T1.1 err msg" "must be a string" "$(body "$R")"

LONG=$(python3 -c "print('a'*601)")
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots" "$TOKEN_B" "{\"title\":\"$LONG\"}")
chk "T1.2 create title=601chars -> 400" 400 "$(code "$R")"
chkin "T1.2 err msg" "512" "$(body "$R")"

R=$(api POST "/api/v2/meta/bases/$SRC/snapshots" "$TOKEN_B" '{}')
chk "T1.3 create empty-body -> 200" 200 "$(code "$R")"
S1=$(body "$R" | jget "['id']")
log "  S1 snapshot id: $S1 status(body): $(body "$R" | head -c 300)"

# T1.3b processing-window race: restore immediately (empty base may complete fast)
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots/$S1/restore" "$TOKEN_B" '{}')
C=$(code "$R")
if [ "$C" = "400" ]; then
  log "PASS T1.3b restore-during-processing -> 400 (race won) body: $(body "$R" | head -c 200)"
elif [ "$C" = "200" ]; then
  log "OBS T1.3b snapshot already completed before restore (tiny base, race lost) -> got 200, restored base: $(body "$R" | head -c 120)"
else
  log "FAIL T1.3b unexpected code=$C body: $(body "$R" | head -c 200)"
fi

R=$(api POST "/api/v2/meta/bases/$SRC/snapshots/nonexistent-id/restore" "$TOKEN_B" '{}')
chk "T1.4 restore non-existent snapshot id -> 404" 404 "$(code "$R")"

R=$(api DELETE "/api/v2/meta/bases/$SRC/snapshots/nonexistent-id" "$TOKEN_B")
chk "T1.5 delete non-existent snapshot id -> 404" 404 "$(code "$R")"

R=$(api GET "/api/v2/meta/bases/$XBASE/snapshots/$S1" "$TOKEN_B")
chk "T1.6a cross-base GET snapshot via other base -> 404" 404 "$(code "$R")"
R=$(api POST "/api/v2/meta/bases/$XBASE/snapshots/$S1/restore" "$TOKEN_B" '{}')
chk "T1.6b cross-base restore via other base -> 404" 404 "$(code "$R")"
R=$(api DELETE "/api/v2/meta/bases/$XBASE/snapshots/$S1" "$TOKEN_B")
chk "T1.6c cross-base delete via other base -> 404" 404 "$(code "$R")"

# ============ T2: state machine ============
sec "T2 state machine (processing/completed/error)"

# wait S1 completed
SC=""
for i in $(seq 1 45); do
  R=$(api GET "/api/v2/meta/bases/$SRC/snapshots/$S1" "$TOKEN_B")
  SC=$(body "$R" | jget "['status']")
  [ "$SC" = "completed" ] && break
  [ "$SC" = "error" ] && break
  sleep 2
done
SNAP_BASE=$(body "$R" | jget "['snapshot_base_id']")
log "  S1 status after wait: ${SC:-UNDEF} snap_base: $SNAP_BASE"
chk "T2.1 snapshot S1 reaches completed" completed "${SC:-UNDEF}"
chk "T2.1b snapshot_base exists in DB (deleted=false)" "1" "$(dbq "select count(*) as n from nc_bases_v2 where id='$SNAP_BASE' and deleted=false" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"

# T2.2 processing restore -> 400 (deterministic retry window via fresh snapshots)
PROC_OK=""
for try in 1 2 3; do
  R=$(api POST "/api/v2/meta/bases/$SRC/snapshots" "$TOKEN_B" "{\"title\":\"f07r3b_proc_try$try\"}")
  SP=$(body "$R" | jget "['id']")
  [ -n "$SP" ] || continue
  RP=$(api POST "/api/v2/meta/bases/$SRC/snapshots/$SP/restore" "$TOKEN_B" '{}')
  CP=$(code "$RP")
  if [ "$CP" = "400" ]; then
    chk "T2.2 restore-while-processing -> 400 (try$try)" 400 400
    chkin "T2.2 err msg" "not ready" "$(body "$RP")"
    DBS=$(dbq "select status as s from nc_snapshots where id='$SP'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["s"])' 2>/dev/null)
    log "  (db status of $SP at that moment: ${DBS:-?})"
    PROC_OK=1
    R2=$(api DELETE "/api/v2/meta/bases/$SRC/snapshots/$SP" "$TOKEN_B"); log "  cleanup proc-try$try snapshot: $(code "$R2")"
    break
  else
    log "  (try$try: snapshot completed before restore landed, got $CP)"
    [ "$CP" = "200" ] && { RB=$(body "$RP" | jget "['base_id']"); [ -n "$RB" ] && CLEAN_BASES+=("$RB"); }
    R2=$(api DELETE "/api/v2/meta/bases/$SRC/snapshots/$SP" "$TOKEN_B"); log "  cleanup proc-try$try snapshot: $(code "$R2")"
  fi
done
[ -n "$PROC_OK" ] || log "OBS T2.2 processing window too narrow on empty base after 3 tries (400-on-processing could not be observed via race); error-state restore 400 is covered in T2.4"

# T2.3 completed restore x2 -> independent restores
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots/$S1/restore" "$TOKEN_B" '{}')
chk "T2.3a restore #1 -> 200" 200 "$(code "$R")"
R1B=$(body "$R" | jget "['base_id']")
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots/$S1/restore" "$TOKEN_B" '{}')
chk "T2.3b restore #2 -> 200 (independent, still completed)" 200 "$(code "$R")"
R2B=$(body "$R" | jget "['base_id']")
if [ -n "$R1B" ] && [ -n "$R2B" ]; then
  if [ "$R1B" != "$R2B" ]; then log "PASS T2.3c restores produced distinct bases ($R1B vs $R2B)"; else log "FAIL T2.3c restores returned identical base id $R1B"; fi
  for RB in $R1B $R2B; do
    CLEAN_BASES+=("$RB")
    RR=$(api GET "/api/v2/meta/bases/$RB" "$TOKEN_B")
    chk "T2.3d restored base $RB exists" 200 "$(code "$RR")"
  done
  RRS=$(api GET "/api/v2/meta/bases/$R1B" "$TOKEN_B")
  chkin "T2.3e restored base title has '(restored)'" "(restored)" "$(body "$RRS")"
fi
# snapshot status must remain completed after 2 restores
RS=$(api GET "/api/v2/meta/bases/$SRC/snapshots/$S1" "$TOKEN_B")
chk "T2.3f snapshot still completed after restores" completed "$(body "$RS" | jget "['status']")"

# T2.4 manual soft-delete of the COPY base (API delete = Base.softDelete, lands deleted=true; DB direct update is masked by in-process mock cache)
R=$(api DELETE "/api/v2/meta/bases/$SNAP_BASE" "$TOKEN_B")
log "  manual soft-delete of copy base $SNAP_BASE -> code $(code "$R")"
chk "T2.4a copy base soft-deleted in DB" "1" "$(dbq "select count(*) as n from nc_bases_v2 where id='$SNAP_BASE' and deleted=true" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
R=$(api GET "/api/v2/meta/bases/$SRC/snapshots/$S1" "$TOKEN_B")
chk "T2.4b GET snapshot derives status=error" error "$(body "$R" | jget "['status']")"
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots/$S1/restore" "$TOKEN_B" '{}')
chk "T2.4c restore in error state -> 400" 400 "$(code "$R")"
chkin "T2.4c err msg" "not ready" "$(body "$R")"

# ============ T3: delete snapshot ============
sec "T3 delete snapshot -> copy 404 + DB deleted + zero variable residue"
R=$(api DELETE "/api/v2/meta/bases/$SRC/snapshots/$S1" "$TOKEN_B")
chk "T3.1 delete snapshot -> 200" 200 "$(code "$R")"
R=$(api GET "/api/v2/meta/bases/$SNAP_BASE" "$TOKEN_B")
chk "T3.2 copy base GET -> 404" 404 "$(code "$R")"
chk "T3.3 copy base deleted=true in DB" "1" "$(dbq "select count(*) as n from nc_bases_v2 where id='$SNAP_BASE' and deleted=true" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
chk "T3.4 zero variable rows on copy base" "0" "$(dbq "select count(*) as n from nc_base_variables where base_id='$SNAP_BASE'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
R=$(api GET "/api/v2/meta/bases/$SRC/snapshots/$S1" "$TOKEN_B")
chk "T3.5 snapshot row gone -> 404" 404 "$(code "$R")"

# ============ T4: source base soft-delete clears nc_snapshots (R2 hook) ============
sec "T4 source base soft-delete -> nc_snapshots rows cleared (R2 hook regression)"
R=$(api POST /api/v2/meta/bases "$TOKEN_B" '{"title":"f07r3b_hk"}')
HK=$(body "$R" | jget "['id']")
chk "T4.0 create hook base" 200 "$(code "$R")"
R=$(api POST "/api/v2/meta/bases/$HK/snapshots" "$TOKEN_B" '{"title":"f07r3b_hk_snap"}')
HS=$(body "$R" | jget "['id']")
HBASE=""
for i in $(seq 1 45); do
  R=$(api GET "/api/v2/meta/bases/$HK/snapshots/$HS" "$TOKEN_B")
  HSC=$(body "$R" | jget "['status']")
  [ "$HSC" = "completed" -o "$HSC" = "error" ] && break
  sleep 2
done
HBASE=$(body "$R" | jget "['snapshot_base_id']")
chk "T4.1 hook-base snapshot completed" completed "${HSC:-UNDEF}"
chk "T4.1b snapshot row exists before source delete" "1" "$(dbq "select count(*) as n from nc_snapshots where base_id='$HK'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
R=$(api DELETE "/api/v2/meta/bases/$HK" "$TOKEN_B")
chk "T4.2 soft-delete source base -> 200" 200 "$(code "$R")"
chk "T4.3 nc_snapshots rows for source base = 0" "0" "$(dbq "select count(*) as n from nc_snapshots where base_id='$HK'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')"
log "  (hook snapshot copy base $HBASE left as trash — platform semantics; also soft-deleting it for hygiene)"
R=$(api DELETE "/api/v2/meta/bases/$HBASE" "$TOKEN_B") && log "  copy base cleanup code: $(code "$R")"

# ============ T5: permission matrix ============
sec "T5 permission matrix (401/403)"
R=$(curl -s -m 10 -o /tmp/f07r3b_last.json -w '%{http_code}' "$API/api/v2/meta/bases/$SRC/snapshots")
chk "T5.1 no-token GET snapshots -> 401" 401 "$R"

# fresh perm base owned by B; invite A with evolving role
R=$(api POST /api/v2/meta/bases "$TOKEN_B" '{"title":"f07r3b_perm"}')
PB=$(body "$R" | jget "['id']")
chk "T5.0 create perm base" 200 "$(code "$R")"
CLEAN_BASES+=("$PB")
R=$(api POST "/api/v2/meta/bases/$PB/users" "$TOKEN_B" '{"email":"f01e2e@ce-ee.local","roles":"viewer"}')
chk "T5.0b invite f01e2e as viewer" 200 "$(code "$R")"
# find A's nc user id (baseUserUpdate PATCH :userId resolves nc_users_v2)
PU=$(dbq "select id as i from nc_users_v2 where email='f01e2e@ce-ee.local' limit 1" --one | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("i",""))' 2>/dev/null)
log "  A user id: $PU"

R=$(api GET "/api/v2/meta/bases/$PB/snapshots" "$TOKEN_A")
chk "T5.2a viewer GET list -> 403" 403 "$(code "$R")"
R=$(api POST "/api/v2/meta/bases/$PB/snapshots" "$TOKEN_A" '{"title":"f07r3b_by_viewer"}')
chk "T5.2b viewer create -> 403" 403 "$(code "$R")"
R=$(api PATCH "/api/v2/meta/bases/$PB/users/$PU" "$TOKEN_B" '{"roles":"editor"}')
chk "T5.3-0 promote A to editor" 200 "$(code "$R")"
R=$(api POST "/api/v2/meta/bases/$PB/snapshots" "$TOKEN_A" '{"title":"f07r3b_by_editor"}')
chk "T5.3 editor create -> 403" 403 "$(code "$R")"
R=$(api DELETE "/api/v2/meta/bases/$PB/snapshots/whatever" "$TOKEN_A")
chk "T5.3b editor delete -> 403 (Acl before 404)" 403 "$(code "$R")"
R=$(api PATCH "/api/v2/meta/bases/$PB/users/$PU" "$TOKEN_B" '{"roles":"creator"}')
chk "T5.4-0 promote A to creator" 200 "$(code "$R")"
R=$(api POST "/api/v2/meta/bases/$PB/snapshots" "$TOKEN_A" '{"title":"f07r3b_by_creator"}')
chk "T5.4 creator create -> 200" 200 "$(code "$R")"
CS=$(body "$R" | jget "['id']")
[ -n "$CS" ] && { R=$(api DELETE "/api/v2/meta/bases/$PB/snapshots/$CS" "$TOKEN_A"); log "  creator-created snapshot cleanup: $(code "$R")"; }

# ============ T6: secret variables & snapshot copy ============
sec "T6 snapshot copy vs secret variables (fork: duplicateBase does not copy variables)"
R=$(api POST "/api/v2/meta/bases/$SRC/variables" "$TOKEN_B" '{"key":"f07r3b_SECRET_KEY","value":"s3cr3t-value-abc","type":"secret","description":"f07r3b enc probe"}')
chk "T6.1 create secret variable on src -> 200" 200 "$(code "$R")"
SV=$(body "$R" | jget "['id']")
R=$(api POST "/api/v2/meta/bases/$SRC/snapshots" "$TOKEN_B" '{"title":"f07r3b_enc_snap"}')
ES=$(body "$R" | jget "['id']")
for i in $(seq 1 45); do
  R=$(api GET "/api/v2/meta/bases/$SRC/snapshots/$ES" "$TOKEN_B")
  ESC=$(body "$R" | jget "['status']")
  [ "$ESC" = "completed" -o "$ESC" = "error" ] && break
  sleep 2
done
EBASE=$(body "$R" | jget "['snapshot_base_id']")
chk "T6.2 enc snapshot completed" completed "${ESC:-UNDEF}"
VSRCCNT=$(dbq "select count(*) as n from nc_base_variables where base_id='$SRC'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')
VSNAPCNT=$(dbq "select count(*) as n from nc_base_variables where base_id='$EBASE'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])')
chk "T6.3 source base has 1 variable row" "1" "$VSRCCNT"
log "T6.4 snapshot-copy variable rows: $VSNAPCNT (fork design: duplicateBase does not copy variables — documented R1 limitation; 0 = behavior confirmed, not a leak path)"
if [ "$VSNAPCNT" != "0" ]; then
  log "  -- unexpected rows on copy; checking ciphertext:"
  dbq "select key, value from nc_base_variables where base_id='$EBASE'" >> "$LOG"
fi
SRVAL=$(dbq "select value from nc_base_variables where base_id='$SRC' and key='f07r3b_SECRET_KEY'" --one | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("value",""))' 2>/dev/null)
case "$SRVAL" in
  *s3cr3t-value-abc*) log "FAIL T6.5 source secret variable stored in PLAINTEXT (NC_CONNECTION_ENCRYPT_KEY not applied?)";;
  "") log "OBS T6.5 could not read source variable value from DB";;
  *) log "PASS T6.5 source secret variable ciphertext (not plaintext) [${SRVAL:0:40}...]";;
esac
# cleanup enc snapshot + copy
[ -n "$ES" ] && { R=$(api DELETE "/api/v2/meta/bases/$SRC/snapshots/$ES" "$TOKEN_B"); log "  enc snapshot cleanup: $(code "$R")"; }
[ -n "$EBASE" ] && { R=$(api DELETE "/api/v2/meta/bases/$EBASE" "$TOKEN_B"); log "  enc copy base cleanup: $(code "$R")"; }
[ -n "$SV" ] && { R=$(api DELETE "/api/v2/meta/bases/$SRC/variables/$SV" "$TOKEN_B"); log "  src secret variable cleanup: $(code "$R")"; }

# ============ Cleanup ============
sec "CLEANUP"
for RB in "${CLEAN_BASES[@]}"; do
  R=$(api DELETE "/api/v2/meta/bases/$RB" "$TOKEN_B")
  log "  delete base $RB -> $(code "$R")"
done
R=$(dbq "select count(*) as n from nc_snapshots s join nc_bases_v2 b on s.base_id=b.id where b.title like 'f07r3b%'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["n"])' 2>/dev/null)
log "  residual f07r3b snapshot rows (expect 0): ${R:-ERR}"

log ""
log "== DONE =="
