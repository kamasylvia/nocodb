#!/bin/zsh
# f05r3b_run.sh — F05 Variables R3 对抗回归(第2路 集成测试-对抗面)
# 目标库: nocodb-dev ONLY. 后端 http://127.0.0.1:8080 (勿重启).
set -u
API=http://127.0.0.1:8080
REPO=/Volumes/UNITEK/Documents/Development/nocodb
W=$REPO/.work/ee-ce
LOG=$W/f05r3b_results.txt
: > "$LOG"

log() { print -r -- "$1" >> "$LOG"; }
sec() { log ""; log "== $1 =="; }
chk() { # name expected actual
  if [ "$2" = "$3" ]; then log "PASS ${1} (=${3})"; else log "FAIL ${1} expected=[${2}] got=[${3}]"; fi
}

# wait for backend (dev server may be restarting)
for i in $(seq 1 60); do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API/api/v2/meta/bases" 2>/dev/null)
  [ "$C" != "000" ] && [ -n "$C" ] && break
  sleep 2
done

# ---------- DB env (Infisical KDL, nocodb-dev ONLY) ----------
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
ITOK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
eval $(infisical secrets --token "$ITOK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^DB_(HOST|PORT|USER|PASSWORD)=' | sed 's/^/export /')
export FDB_HOST=qnap.elf-balance.ts.net FDB_PORT="${DB_PORT:-5432}" FDB_USER="$DB_USER" FDB_PASSWORD="$DB_PASSWORD"
dbq() { uv run --with pg8000 python3 "$W/f05r3b_dbq.py" "$1" ${2:-}; }
dbc() { dbq "$1" --one | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("n","ERR"))'; }

# ---------- API helpers ----------
signin_a() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null; }
signin_b() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f05r3b@ce-ee.local","password":"F05r3b!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null; }
TOKEN_A=$(signin_a)
TOKEN_B=$(signin_b)
[ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] || { log "FATAL signin failed"; exit 1; }
log "signin ok: lenA=${#TOKEN_A} lenB=${#TOKEN_B}"

api() { # method path token [data]
  local m=$1 p=$2 t=$3 d=${4:-} tf=/tmp/f05r3b_last.json
  if [ -n "$d" ]; then
    CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d")
  else
    CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t")
  fi
  # A token may be invalidated mid-run by an external token_version bump
  if [ "$CODE" = "401" ] && [ "$t" = "$TOKEN_A" ] && [ "$m" != "SIGNIN" ]; then
    local NT=$(signin_a)
    if [ -n "$NT" ]; then
      TOKEN_A="$NT"; t="$NT"; log "  (token A refreshed mid-run)"
      if [ -n "$d" ]; then
        CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d")
      else
        CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t")
      fi
    fi
  fi
  BODY=$(cat "$tf")
}
jget() { print -r -- "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1','__absent__'))" 2>/dev/null || echo "__parse_err__"; }

crypt() { # ciphertext key -> plaintext
  (cd "$REPO/packages/nocodb" && node -e "const C=require('crypto-js');console.log(C.AES.decrypt(process.argv[1],process.argv[2]).toString(C.enc.Utf8))" "$1" "$2")
}

# ---------- setup: base ----------
sec "SETUP create base (owner A)"
api POST /api/v2/meta/bases "$TOKEN_A" '{"title":"f05r3b_base","description":"f05r3b r3 review"}'
log "create base: $CODE ${BODY:0:200}"
BID=$(jget id)
[ "$BID" != "__absent__" ] && [ -n "$BID" ] || { log "FATAL base create failed"; exit 1; }
log "BID=$BID"
WSID=$(dbc "SELECT count(*) AS n FROM nc_base_users_v2 WHERE base_id='$BID' AND fk_user_id='usjb247r37d3pmk1' AND roles='owner'")
chk "setup: creator base_users row=owner" "1" "$WSID"
WSID=$(dbq "SELECT fk_workspace_id FROM nc_base_users_v2 WHERE base_id='$BID' AND fk_user_id='usjb247r37d3pmk1'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["fk_workspace_id"])')
log "WSID=$WSID"

# ---------- T6a 无角色 ----------
sec "T6a B(f05r3b, org-viewer, no base role) on A base"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_B"
chk "T6a list no-role -> 403" "403" "$CODE"
log "  body: ${BODY:0:160}"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_B" '{"key":"F05R3B_NOACCESS","value":"x","type":"text"}'
chk "T6a create no-role -> 403" "403" "$CODE"
log "  body: ${BODY:0:160}"
api GET "/api/v2/meta/bases/$BID/variables/vdummys3b" "$TOKEN_B"
chk "T6a get no-role -> 403" "403" "$CODE"

# ---------- T1 缓存双重解密回归守卫 ----------
sec "T1 cache double-decrypt guard (secret F05R3B_SECRET)"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" '{"key":"F05R3B_SECRET","value":"s3cr3t-v1","type":"secret","description":"cache guard"}'
chk "T1 create secret -> 200" "200" "$CODE"
log "  body: ${BODY:0:260}"
VID=$(jget id)
GV=$(jget value)
chk "T1 create resp value=s3cr3t-v1" "s3cr3t-v1" "$GV"
CV1=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SECRET' AND value LIKE 'U2FsdGVk%'")
chk "T1 DB row is ciphertext" "1" "$CV1"
DBV=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SECRET'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T1 DB ciphertext decrypts to s3cr3t-v1" "s3cr3t-v1" "$(crypt "$DBV" "dev-only-ce-ee-encrypt-key-0f1e2d3c")"
# 5x single GET constant
CONS="ok"
for i in 1 2 3 4 5; do
  api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
  [ "$CODE" = "200" ] || CONS="fail-code-$CODE"
  V=$(jget value); [ "$V" = "s3cr3t-v1" ] || CONS="fail-val-$i=$V"
done
chk "T1 5x GET constant s3cr3t-v1" "ok" "$CONS"
# list/GET alternate x3
CONS="ok"
for i in 1 2 3; do
  api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
  MASKED=$(print -r -- "$BODY" | python3 -c 'import sys,json;rs=json.load(sys.stdin)["list"];r=[x for x in rs if x["key"]=="F05R3B_SECRET"];print("masked" if (r and "value" not in r[0]) else "leak")' 2>/dev/null || echo "parse_err")
  [ "$MASKED" = "masked" ] || CONS="fail-list-$i=$MASKED"
  api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
  V=$(jget value); [ "$V" = "s3cr3t-v1" ] || CONS="fail-get-$i=$V"
done
chk "T1 list(masked)/GET(v1) alternate x3" "ok" "$CONS"
# PATCH value -> 3x constant
api PATCH "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A" '{"value":"s3cr3t-v2"}'
chk "T1 PATCH value -> 200" "200" "$CODE"
V=$(jget value); chk "T1 PATCH resp value=v2" "s3cr3t-v2" "$V"
CONS="ok"
for i in 1 2 3; do
  api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
  V=$(jget value); [ "$V" = "s3cr3t-v2" ] || CONS="fail-$i=$V"
done
chk "T1 3x GET constant s3cr3t-v2" "ok" "$CONS"
DBV=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SECRET'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T1 DB after PATCH decrypts to v2" "s3cr3t-v2" "$(crypt "$DBV" "dev-only-ce-ee-encrypt-key-0f1e2d3c")"

# ---------- T2 加密状态机 ----------
sec "T2 state machine F05R3B_SM: text(A)->secret->value(B)->text"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" '{"key":"F05R3B_SM","value":"sm-plain-A","type":"text","description":"sm"}'
chk "T2 create text -> 200" "200" "$CODE"
SMID=$(jget id)
DBV=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SM'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T2A DB plaintext == sm-plain-A" "sm-plain-A" "$DBV"
api GET "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A"
chk "T2A API get == sm-plain-A" "sm-plain-A" "$(jget value)"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
LST=$(print -r -- "$BODY" | python3 -c 'import sys,json;rs=json.load(sys.stdin)["list"];r=[x for x in rs if x["key"]=="F05R3B_SM"];print(r[0]["value"] if r else "__no__")')
chk "T2A list shows sm-plain-A (text unmasked)" "sm-plain-A" "$LST"
# step B: flip to secret
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"type":"secret"}'
chk "T2B PATCH type=secret -> 200" "200" "$CODE"
DBV=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SM'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
CT=$(print -r -- "$DBV" | python3 -c 'import sys;v=sys.stdin.read().strip();print("yes" if v.startswith("U2FsdGVk") and v!="sm-plain-A" else "no:"+v[:20])')
chk "T2B DB ciphertext form" "yes" "$CT"
chk "T2B DB ciphertext decrypts to sm-plain-A" "sm-plain-A" "$(crypt "$DBV" "dev-only-ce-ee-encrypt-key-0f1e2d3c")"
api GET "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A"
chk "T2B API get == sm-plain-A" "sm-plain-A" "$(jget value)"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
MASKED=$(print -r -- "$BODY" | python3 -c 'import sys,json;rs=json.load(sys.stdin)["list"];r=[x for x in rs if x["key"]=="F05R3B_SM"];print("masked" if (r and "value" not in r[0]) else "leak")')
chk "T2B list masked" "masked" "$MASKED"
# step C: change value under secret
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"value":"sm-plain-B"}'
chk "T2C PATCH value(B) -> 200" "200" "$CODE"
DBV2=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SM'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
CT=$(print -r -- "$DBV2" | python3 -c 'import sys;v=sys.stdin.read().strip();print("yes" if v.startswith("U2FsdGVk") and v!="'"$DBV"'" else "no")')
chk "T2C DB new ciphertext (differs, ciphertext form)" "yes" "$CT"
chk "T2C DB ciphertext decrypts to sm-plain-B" "sm-plain-B" "$(crypt "$DBV2" "dev-only-ce-ee-encrypt-key-0f1e2d3c")"
api GET "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A"
chk "T2C API get == sm-plain-B" "sm-plain-B" "$(jget value)"
# step D: flip back to text
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"type":"text"}'
chk "T2D PATCH type=text -> 200" "200" "$CODE"
DBV3=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SM'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T2D DB plaintext == sm-plain-B" "sm-plain-B" "$DBV3"
api GET "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A"
chk "T2D API get == sm-plain-B" "sm-plain-B" "$(jget value)"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
LST=$(print -r -- "$BODY" | python3 -c 'import sys,json;rs=json.load(sys.stdin)["list"];r=[x for x in rs if x["key"]=="F05R3B_SM"];print(r[0]["value"] if r else "__no__")')
chk "T2D list shows sm-plain-B" "sm-plain-B" "$LST"

# ---------- T3 非法输入矩阵 ----------
sec "T3 invalid input matrix (all -> 400)"
t3() { # label payload
  api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" "$2"
  chk "T3 $1 -> 400" "400" "$CODE"
  log "  body: ${BODY:0:140}"
}
t3 "key lowercase"      '{"key":"f05r3b_lower","value":"v","type":"text"}'
t3 "key empty"          '{"key":"","value":"v","type":"text"}'
t3 "key missing"        '{"value":"v","type":"text"}'
t3 "key digit-start"    '{"key":"1F05R3B","value":"v","type":"text"}'
t3 "key with hyphen"    '{"key":"F05R3B-A","value":"v","type":"text"}'
t3 "key >255"           "{\"key\":\"$(python3 -c 'print("A"*256)')\",\"value\":\"v\",\"type\":\"text\"}"
t3 "value int"          '{"key":"F05R3B_T3OK","value":123,"type":"text"}'
t3 "value object"       '{"key":"F05R3B_T3OK","value":{"x":1},"type":"text"}'
t3 "value array"        '{"key":"F05R3B_T3OK","value":["a"],"type":"text"}'
t3 "value bool"         '{"key":"F05R3B_T3OK","value":true,"type":"text"}'
t3 "type bogus str"     '{"key":"F05R3B_T3OK","value":"v","type":"hacker"}'
t3 "type int"           '{"key":"F05R3B_T3OK","value":"v","type":123}'
t3 "type null"          '{"key":"F05R3B_T3OK","value":"v","type":null}'
# PATCH matrix on F05R3B_SM (existing)
t3p() { # label payload
  api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" "$2"
  chk "T3P $1 -> 400" "400" "$CODE"
  log "  body: ${BODY:0:140}"
}
t3p "patch type bogus"  '{"type":"bogus"}'
t3p "patch value int"   '{"value":123}'
t3p "patch value object" '{"value":{"a":1}}'
t3p "patch key immutable" '{"key":"F05R3B_RENAMED"}'
t3p "patch empty body"  '{}'
V=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_SM'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T3P after matrix SM value intact" "sm-plain-B" "$V"
NC=$(api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"; print -r -- "$BODY" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["list"]))')
chk "T3 no junk rows in base (count=3)" "3" "$NC"

# ---------- T4 PATCH 语义 ----------
sec "T4 PATCH semantics (R2 fix regression)"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" '{"key":"F05R3B_P1","value":"keep-me","type":"text","description":"d0"}'
chk "T4 create P1 -> 200" "200" "$CODE"
P1ID=$(jget id)
api PATCH "/api/v2/meta/bases/$BID/variables/$P1ID" "$TOKEN_A" '{"value":null}'
chk "T4 PATCH value:null -> 200" "200" "$CODE"
V=$(jget value); chk "T4 value cleared to empty-string" "" "$V"
api PATCH "/api/v2/meta/bases/$BID/variables/$P1ID" "$TOKEN_A" '{"description":"only-desc"}'
chk "T4 PATCH desc-only -> 200" "200" "$CODE"
V=$(jget value); chk "T4 value still empty" "" "$V"
D=$(jget description); chk "T4 description updated" "only-desc" "$D"
api PATCH "/api/v2/meta/bases/$BID/variables/$P1ID" "$TOKEN_A" '{"value":"real-val"}'
chk "T4 set real-val -> 200" "200" "$CODE"
api PATCH "/api/v2/meta/bases/$BID/variables/$P1ID" "$TOKEN_A" '{"description":"x2"}'
chk "T4 desc-only after value set -> 200" "200" "$CODE"
V=$(jget value); chk "T4 R2 regression: value untouched by desc-only patch" "real-val" "$V"
DBV=$(dbq "SELECT value FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_P1'" --one | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
chk "T4 DB value intact" "real-val" "$DBV"
# desc-only on SECRET must not need value path
api PATCH "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A" '{"description":"sec-desc"}'
chk "T4 desc-only on secret -> 200" "200" "$CODE"
V=$(jget value); chk "T4 secret value untouched" "s3cr3t-v2" "$V"

# ---------- T7 并发同 key ----------
sec "T7 race: 5 parallel POST same key"
RB='{"key":"F05R3B_RACE","value":"r","type":"text"}'
for i in 1 2 3 4 5; do
  ( curl -s -o "/tmp/f05r3b_race_$i" -w '%{http_code}' -X POST "$API/api/v2/meta/bases/$BID/variables" -H "xc-auth: $TOKEN_A" -H 'Content-Type: application/json' -d "$RB" > "/tmp/f05r3b_race_code_$i" ) &
done
wait
R200=$(cat /tmp/f05r3b_race_code_{1,2,3,4,5} 2>/dev/null | grep -c '^200$')
R400=$(cat /tmp/f05r3b_race_code_{1,2,3,4,5} 2>/dev/null | grep -c '^400$')
chk "T7 success count = 1" "1" "$R200"
chk "T7 rejected count = 4" "4" "$R400"
NR=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_RACE'")
chk "T7 DB rows for key = 1" "1" "$NR"
rm -f /tmp/f05r3b_race_* 

# ---------- T8 UI 契约 ----------
sec "T8 UI contract: GET single prefill fields"
api GET "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A"
FIELDS=$(print -r -- "$BODY" | python3 -c '
import sys,json
d=json.load(sys.stdin)
need=["key","value","description","type"]
missing=[k for k in need if k not in d]
print("OK" if not missing else "missing:"+",".join(missing))')
chk "T8 text var GET has key/value/description/type" "OK" "$FIELDS"
api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
FIELDS=$(print -r -- "$BODY" | python3 -c '
import sys,json
d=json.load(sys.stdin)
need=["key","value","description","type"]
missing=[k for k in need if k not in d]
tv="secret" if d.get("type")=="secret" else "wrongtype:"+str(d.get("type"))
vv="realval" if d.get("value")=="s3cr3t-v2" else "wrongval"
print("OK" if not missing else "missing:"+",".join(missing), tv, vv)')
chk "T8 secret var GET has key/value/description/type (decrypted prefill)" "OK secret realval" "$FIELDS"
log "  secret GET body: ${BODY:0:260}"

# ---------- T6b editor 降权 ----------
sec "T6b editor role -> 403"
INS=$(dbc "INSERT INTO nc_base_users_v2 (base_id, fk_user_id, roles, fk_workspace_id, created_at, updated_at) VALUES ('$BID','us5r5kf7fjnb5wdb','editor','$WSID',now(),now()) RETURNING 1 AS n" )
chk "T6b DB insert editor row" "1" "$INS"
sleep 1
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_B"
chk "T6b editor list -> 403" "403" "$CODE"
log "  body: ${BODY:0:220}"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_B" '{"key":"F05R3B_EDTRY","value":"x","type":"text"}'
chk "T6b editor create -> 403" "403" "$CODE"
log "  body: ${BODY:0:220}"
DEL=$(dbc "DELETE FROM nc_base_users_v2 WHERE base_id='$BID' AND fk_user_id='us5r5kf7fjnb5wdb' RETURNING 1 AS n")
chk "T6b editor row removed" "1" "$DEL"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_B"
chk "T6b after removal no-role -> 403" "403" "$CODE"

# ---------- T5 删 base 零残留 ----------
sec "T5 delete base -> zero residue"
NV=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID'")
chk "T5 pre-delete variables rows=5" "5" "$NV"
api DELETE "/api/v2/meta/bases/$BID" "$TOKEN_A"
chk "T5 base delete -> 200" "200" "$CODE"
log "  body: ${BODY:0:160}"
sleep 2
NV=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID'")
chk "T5 nc_base_variables residue = 0" "0" "$NV"
NU=$(dbc "SELECT count(*) AS n FROM nc_base_users_v2 WHERE base_id='$BID'")
chk "T5 nc_base_users_v2 residue = 0" "0" "$NU"

sec "DONE"
log "BID=$BID (deleted)"
