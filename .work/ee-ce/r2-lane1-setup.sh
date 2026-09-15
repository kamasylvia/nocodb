#!/bin/bash
# R2 lane1 F02 integration test setup — creates fresh base/table/users
# usage: bash r2-lane1-setup.sh   (prints shell-exportable state file path)
set -u
B=http://localhost:8080
PSQL="/opt/homebrew/opt/libpq@18/bin/psql"
PG="postgresql://postgres:postgres@qnap.elf-balance.ts.net:5432/nocodb-dev"
TS=$(date +%s)
S=/tmp/f02r2l1-state.sh
: > $S

jqget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(\"d$1\"))" 2>/dev/null; }

api() { # method path token data
  local m=$1 p=$2 t=$3 d=${4:-}
  if [ -n "$d" ]; then
    curl -s -m 30 -X "$m" "$B$p" -H "xc-auth: $t" -H 'Content-Type: application/json' -d "$d"
  else
    curl -s -m 30 -X "$m" "$B$p" -H "xc-auth: $t"
  fi
}

# ---- users ----
OE="f02r2l1-owner-$TS@t.io"; EE="f02r2l1-editor-$TS@t.io"; CE="f02r2l1-creator-$TS@t.io"
for E in $OE $EE $CE; do
  R=$(curl -s -X POST $B/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"Passw0rd!123\"}")
  echo "$R" | jqget "['token']" >/dev/null || { echo "FAIL signup $E: $R"; exit 1; }
done
# owner promoted to super via psql BEFORE signin
$PSQL "$PG" -tAc "UPDATE nc_users_v2 SET roles='super' WHERE email='$OE'" >/dev/null || { echo FAIL psql-promote; exit 1; }

OT=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$OE\",\"password\":\"Passw0rd!123\"}" | jqget "['token']")
ET=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EE\",\"password\":\"Passw0rd!123\"}" | jqget "['token']")
CT=$(curl -s -X POST $B/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$CE\",\"password\":\"Passw0rd!123\"}" | jqget "['token']")
[ -n "$OT" ] && [ -n "$ET" ] && [ -n "$CT" ] || { echo FAIL signin; exit 1; }

OID=$($PSQL "$PG" -tAc "SELECT id FROM nc_users_v2 WHERE email='$OE'")
EID=$($PSQL "$PG" -tAc "SELECT id FROM nc_users_v2 WHERE email='$EE'")
CID=$($PSQL "$PG" -tAc "SELECT id FROM nc_users_v2 WHERE email='$CE'")

# ---- base + table ----
R=$(api POST /api/v2/meta/bases "$OT" "{\"title\":\"f02r2l1-base-$TS\"}")
BID=$(echo "$R" | jqget "['id']") || exit 1
[ -n "$BID" ] || { echo "FAIL base: $R"; exit 1; }

# invite editor+creator
api POST /api/v2/meta/bases/$BID/users "$OT" "{\"email\":\"$EE\",\"roles\":\"editor\"}" >/dev/null
api POST /api/v2/meta/bases/$BID/users "$OT" "{\"email\":\"$CE\",\"roles\":\"creator\"}" >/dev/null

R=$(api POST /api/v2/meta/bases/$BID/tables "$OT" "{\"table_name\":\"T1\",\"title\":\"T1\",\"meta\":{},\"columns\":[{\"column_name\":\"Title\",\"title\":\"Title\",\"uidt\":\"SingleLineText\"},{\"column_name\":\"Secret\",\"title\":\"Secret\",\"uidt\":\"SingleLineText\"}]}")
TID=$(echo "$R" | jqget "['id']") || exit 1
[ -n "$TID" ] || { echo "FAIL table: $R"; exit 1; }

R=$(api GET /api/v2/meta/tables/$TID "$OT")
COL_TITLE=$(echo "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Title'][0])")
COL_SECRET=$(echo "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Secret'][0])")

# T2: control table, no grants ever
R=$(api POST /api/v2/meta/bases/$BID/tables "$OT" "{\"table_name\":\"T2\",\"title\":\"T2\",\"meta\":{},\"columns\":[{\"column_name\":\"Title\",\"title\":\"Title\",\"uidt\":\"SingleLineText\"}]}")
T2=$(echo "$R" | jqget "['id']")

# seed one row in T1 (Secret seeded)
api POST /api/v2/tables/$TID/records "$OT" "{\"Title\":\"seed\",\"Secret\":\"s0\"}" >/dev/null

# form view on T1 + share
R=$(api POST /api/v2/meta/tables/$TID/views "$OT" '{"title":"F1","type":"form"}')
VID=$(echo "$R" | jqget "['id']")
R=$(api POST /api/v2/meta/views/$VID/share "$OT" '{}')
UUID=$(echo "$R" | jqget "['uuid']")

cat >> $S <<EOF
B=$B
BID=$BID
TID=$TID
T2=$T2
COL_TITLE=$COL_TITLE
COL_SECRET=$COL_SECRET
VID=$VID
UUID=$UUID
OT=$OT
ET=$ET
CT=$CT
OE=$OE
EE=$EE
CE=$CE
OID=$OID
EID=$EID
CID=$CID
TS=$TS
EOF
echo "state written to $S"
