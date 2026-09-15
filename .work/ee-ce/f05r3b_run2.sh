#!/bin/zsh
# f05r3b_run2.sh — F05 R3 对抗回归补测(裸数组解析修正 + race 复跑 + type 500 复现)
set -u
API=http://127.0.0.1:8080
REPO=/Volumes/UNITEK/Documents/Development/nocodb
W=$REPO/.work/ee-ce
LOG=$W/f05r3b_results2.txt
: > "$LOG"

log() { print -r -- "$1" >> "$LOG"; }
sec() { log ""; log "== $1 =="; }
chk() {
  if [ "$2" = "$3" ]; then log "PASS ${1} (=${3})"; else log "FAIL ${1} expected=[${2}] got=[${3}]"; fi
}

set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
ITOK=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
eval $(infisical secrets --token "$ITOK" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^DB_(HOST|PORT|USER|PASSWORD)=' | sed 's/^/export /')
export FDB_HOST=qnap.elf-balance.ts.net FDB_PORT="${DB_PORT:-5432}" FDB_USER="$DB_USER" FDB_PASSWORD="$DB_PASSWORD"
dbc() { uv run --with pg8000 python3 "$W/f05r3b_dbq.py" "$1" --one | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("n","ERR"))'; }

for i in $(seq 1 60); do
  C=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API/api/v2/meta/bases" 2>/dev/null)
  [ "$C" != "000" ] && [ -n "$C" ] && break
  sleep 2
done

signin_a() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null; }
signin_b() { curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f05r3b@ce-ee.local","password":"F05r3b!pass1"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null; }
TOKEN_A=$(signin_a); TOKEN_B=$(signin_b)
[ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] || { log "FATAL signin failed"; exit 1; }
log "signin ok lenA=${#TOKEN_A} lenB=${#TOKEN_B}"

api() {
  local m=$1 p=$2 t=$3 d=${4:-} tf=/tmp/f05r3b_last2.json
  if [ -n "$d" ]; then
    CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d")
  else
    CODE=$(curl -s -m 20 -o "$tf" -w '%{http_code}' -X "$m" "$API$p" -H "xc-auth: $t")
  fi
  if [ "$CODE" = "401" ] && [ "$t" = "$TOKEN_A" ]; then
    local NT=$(signin_a)
    if [ -n "$NT" ]; then TOKEN_A="$NT"; t="$NT"; log "  (token A refreshed)"
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
# list helpers — response is a bare JSON array
lsval() { # key -> value or __masked__ or __no__
  print -r -- "$BODY" | python3 -c '
import sys,json
rs=json.load(sys.stdin)
if not isinstance(rs,list): print("not-array:"+type(rs).__name__); raise SystemExit
r=[x for x in rs if x.get("key")=="'"$1"'"]
if not r: print("__no__")
elif "value" in r[0]: print(r[0]["value"])
else: print("__masked__")' 2>/dev/null || echo "__parse_err__"
}
lscount() { print -r -- "$BODY" | python3 -c 'import sys,json;rs=json.load(sys.stdin);print(len(rs) if isinstance(rs,list) else "not-array")' 2>/dev/null || echo "__parse_err__"; }

sec "SETUP base2"
api POST /api/v2/meta/bases "$TOKEN_A" '{"title":"f05r3b_base2","description":"f05r3b r3 rerun"}'
BID=$(jget id)
[ -n "$BID" ] && [ "$BID" != "__absent__" ] || { log "FATAL base create: $CODE ${BODY:0:200}"; exit 1; }
log "BID=$BID"

sec "R1 secret list/GET alternate + mask (bare-array shape)"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" '{"key":"F05R3B_SECRET","value":"s3cr3t-v1","type":"secret"}'
VID=$(jget id); log "create secret: $CODE id=$VID"
CONS="ok"
for i in 1 2 3; do
  api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
  M=$(lsval F05R3B_SECRET); [ "$M" = "__masked__" ] || CONS="fail-list-$i=$M"
  api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
  V=$(jget value); [ "$V" = "s3cr3t-v1" ] || CONS="fail-get-$i=$V"
done
chk "R1 list(masked)/GET(v1) alternate x3" "ok" "$CONS"
api PATCH "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A" '{"value":"s3cr3t-v2"}'
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
chk "R1 after PATCH list still masked" "__masked__" "$(lsval F05R3B_SECRET)"
api GET "/api/v2/meta/bases/$BID/variables/$VID" "$TOKEN_A"
chk "R1 after PATCH GET = s3cr3t-v2" "s3cr3t-v2" "$(jget value)"

sec "R2 state machine list-side masks"
api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" '{"key":"F05R3B_SM","value":"sm-plain-A","type":"text"}'
SMID=$(jget id)
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
chk "R2A list text shows value" "sm-plain-A" "$(lsval F05R3B_SM)"
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"type":"secret"}'
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
chk "R2B list secret masked" "__masked__" "$(lsval F05R3B_SM)"
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"value":"sm-plain-B"}'
api PATCH "/api/v2/meta/bases/$BID/variables/$SMID" "$TOKEN_A" '{"type":"text"}'
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
chk "R2D list text shows sm-plain-B" "sm-plain-B" "$(lsval F05R3B_SM)"

sec "R3 POST invalid type — codes (adversarial)"
r3() { # label payload
  api POST "/api/v2/meta/bases/$BID/variables" "$TOKEN_A" "$2"
  log "R3 $1 -> $CODE"
  log "  body: ${BODY:0:400}"
}
r3 "type bogus-str" '{"key":"F05R3B_TX","value":"v","type":"hacker"}'
r3 "type int"       '{"key":"F05R3B_TX","value":"v","type":123}'
r3 "type bool"      '{"key":"F05R3B_TX","value":"v","type":true}'
r3 "type array"     '{"key":"F05R3B_TX","value":"v","type":["secret"]}'
r3 "type object"    '{"key":"F05R3B_TX","value":"v","type":{"t":"secret"}}'
r3 "type null"      '{"key":"F05R3B_T3OK","value":"v","type":null}'

sec "R4 race: 5 parallel POST same key"
RB='{"key":"F05R3B_RACE","value":"r","type":"text"}'
for i in 1 2 3 4 5; do
  ( curl -s -m 20 -o "/tmp/f05r3b_rc_body_$i" -w '%{http_code}' -X POST "$API/api/v2/meta/bases/$BID/variables" -H "xc-auth: $TOKEN_A" -H 'Content-Type: application/json' -d "$RB" >| "/tmp/f05r3b_rc_code_$i" ) &
done
wait
CODES=$(cat /tmp/f05r3b_rc_code_1 /tmp/f05r3b_rc_code_2 /tmp/f05r3b_rc_code_3 /tmp/f05r3b_rc_code_4 /tmp/f05r3b_rc_code_5 | tr '\n' ' ')
log "race codes: $CODES"
R200=$(cat /tmp/f05r3b_rc_code_1 /tmp/f05r3b_rc_code_2 /tmp/f05r3b_rc_code_3 /tmp/f05r3b_rc_code_4 /tmp/f05r3b_rc_code_5 | grep -c 200)
R400=$(cat /tmp/f05r3b_rc_code_1 /tmp/f05r3b_rc_code_2 /tmp/f05r3b_rc_code_3 /tmp/f05r3b_rc_code_4 /tmp/f05r3b_rc_code_5 | grep -c 400)
chk "R4 success=1" "1" "$R200"
chk "R4 rejected=4" "4" "$R400"
NR=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID' AND key='F05R3B_RACE'")
chk "R4 DB rows=1" "1" "$NR"
rm -f /tmp/f05r3b_rc_* 

sec "R5 delete base2 -> variables residue"
api GET "/api/v2/meta/bases/$BID/variables" "$TOKEN_A"
log "pre-delete count=$(lscount)"
api DELETE "/api/v2/meta/bases/$BID" "$TOKEN_A"
chk "R5 base delete -> 200" "200" "$CODE"
sleep 2
NV=$(dbc "SELECT count(*) AS n FROM nc_base_variables WHERE base_id='$BID'")
chk "R5 variables residue=0" "0" "$NV"
sec "DONE2"
