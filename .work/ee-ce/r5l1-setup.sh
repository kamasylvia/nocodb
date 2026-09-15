#!/bin/zsh
. "$(dirname "$0")/r5l1-common.sh"
export PGPASSWORD="$DB_PASSWORD"
export PGPASSWORD="$DB_PASSWORD"
SFX=$RANDOM$RANDOM
O="f02r5l1-owner-$SFX@test.local"; E="f02r5l1-ed-$SFX@test.local"; C="f02r5l1-cr-$SFX@test.local"
PW='F02r5l1!pass123'
B=http://localhost:8080
J() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null; }

# 1. signup all three
for U in "$O" "$E" "$C"; do
  R=$(curl -s -X POST "$B/api/v2/auth/user/signup" -H 'Content-Type: application/json' -d "{\"email\":\"$U\",\"password\":\"$PW\"}")
  echo "signup $U -> $(echo "$R" | head -c 120)"
done

# 2. owner提权 super（signin 前）
"${PSQL}" -h qnap.elf-balance.ts.net -p "$DB_PORT" -U "$DB_USER" -d "$DEVDB" -t -A -c "UPDATE nc_users_v2 SET roles='super' WHERE email='$O'"
"${PSQL}" -h qnap.elf-balance.ts.net -p "$DB_PORT" -U "$DB_USER" -d "$DEVDB" -t -A -c "SELECT email||'='||roles FROM nc_users_v2 WHERE email LIKE '%-$SFX@%'"

# 3. signin all
TO=$(curl -s -X POST "$B/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$O\",\"password\":\"$PW\"}" | J token)
TE=$(curl -s -X POST "$B/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$PW\"}" | J token)
TC=$(curl -s -X POST "$B/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$C\",\"password\":\"$PW\"}" | J token)
echo "tokens: O=${#TO} E=${#TE} C=${#TC}"

# 4. create base
BASE=$(curl -s -X POST "$B/api/v2/meta/bases/" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"name":"f02r5l1-base","type":"database"}')
BID=$(echo "$BASE" | J id); WID=$(echo "$BASE" | J fk_workspace_id)
echo "base: $BID ws=$WID"

# 5. create table with 2 columns
TBL=$(curl -s -X POST "$B/api/v2/meta/bases/$BID/tables" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d '{"table_name":"F02R5L1","columns":[{"title":"Name","column_name":"Name","uidt":"SingleLineText","prompt":"f02r5l1"},{"title":"Secret","column_name":"Secret","uidt":"SingleLineText","prompt":"f02r5l1"}]}')
TID=$(echo "$TBL" | J id); SECRET_COL=$(echo "$TBL" | J id)
SECRET_ID=$(echo "$TBL" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Secret'][0])")
NAME_ID=$(echo "$TBL" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['id'] for c in d['columns'] if c['title']=='Name'][0])")
echo "table: $TID secret_col=$SECRET_ID name_col=$NAME_ID"

# 6. invite editor + creator to base
RE=$(curl -s -X POST "$B/api/v2/meta/bases/$BID/users" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"roles\":\"editor\"}")
RC=$(curl -s -X POST "$B/api/v2/meta/bases/$BID/users" -H "xc-auth: $TO" -H 'Content-Type: application/json' -d "{\"email\":\"$C\",\"roles\":\"creator\"}")
echo "invite E: $(echo "$RE" | head -c 100)"
echo "invite C: $(echo "$RC" | head -c 100)"

# save state
cat > "$(dirname "$0")/r5l1-state.env" <<ST
export O=$O
export E=$E
export C=$C
export PW='$PW'
export BID=$BID
export WID=$WID
export TID=$TID
export SECRET_ID=$SECRET_ID
export NAME_ID=$NAME_ID
export TO=$TO
export TE=$TE
export TC=$TC
export SFX=$SFX
ST
echo STATE_SAVED
