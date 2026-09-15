#!/bin/bash
# R2 F03 lane1 integration test — setup + matrix runner
# Credentials come from env (INFISICAL_* fetched by caller). No secrets here.
API=http://localhost:8080
TS=$(date +%s)
OWNER="lane1r2o${TS}@test.local"
EDITOR="lane1r2e${TS}@test.local"
CREATOR="lane1r2c${TS}@test.local"
OUT=/tmp/f03lane1-$TS.env

jqr() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

# 1) signup owner/editor/creator
for E in "$OWNER" "$EDITOR" "$CREATOR"; do
  R=$(curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' \
    -d "{\"email\":\"$E\",\"password\":\"Passw0rd!123\"}")
  echo "$E signup: $(echo "$R" | head -c 120)"
done

# 2) promote owner to super (pre-signin)
export PGPASSWORD="$DB_PASSWORD"
/opt/homebrew/opt/libpq@18/bin/psql -h qnap.elf-balance.ts.net -p 5432 -U "$DB_USER" -d nocodb-dev -tAc \
  "update nc_users_v2 set roles='super' where email='$OWNER';"

# 3) signin all
OWN_TOK=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$OWNER\",\"password\":\"Passw0rd!123\"}" | jqr "['token']")
EDI_TOK=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EDITOR\",\"password\":\"Passw0rd!123\"}" | jqr "['token']")
CRE_TOK=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$CREATOR\",\"password\":\"Passw0rd!123\"}" | jqr "['token']")
echo "owner token len=${#OWN_TOK} editor=${#EDI_TOK} creator=${#CRE_TOK}"

# 4) create base + tables as owner
B=$(curl -s -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "{\"title\":\"F03L1-$TS\",\"type\":\"database\"}")
BASE_ID=$(echo "$B" | jqr "['id']")
echo "base=$BASE_ID"

mktable() { # name
  curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/tables -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' \
    -d "{\"table_name\":\"$1\",\"columns\":[{\"column_name\":\"Title\",\"uidt\":\"SingleLineText\"}]}"
}
T1=$(mktable Tasks);   T1_ID=$(echo "$T1" | jqr "['id']");   T1_TITLE=$(echo "$T1" | jqr "['title']")
T2=$(mktable Secrets); T2_ID=$(echo "$T2" | jqr "['id']");   T2_TITLE=$(echo "$T2" | jqr "['title']")
T3=$(mktable Logs);    T3_ID=$(echo "$T3" | jqr "['id']");   T3_TITLE=$(echo "$T3" | jqr "['title']")
T4=$(mktable Notes);   T4_ID=$(echo "$T4" | jqr "['id']");   T4_TITLE=$(echo "$T4" | jqr "['title']")
echo "tables: $T1_ID($T1_TITLE) $T2_ID($T2_TITLE) $T3_ID($T3_TITLE) $T4_ID($T4_TITLE)"

# 5) invite editor + creator to base
for pair in "$EDITOR:editor" "$CREATOR:creator"; do
  E="${pair%%:*}"; R="${pair##*:}"
  RI=$(curl -s -X POST $API/api/v2/meta/bases/$BASE_ID/users -H "xc-auth: $OWN_TOK" -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"roles\":\"$R\"}")
  echo "invite $E as $R: $(echo "$RI" | head -c 100)"
  # re-set base role directly to be robust
  /opt/homebrew/opt/libpq@18/bin/psql -h qnap.elf-balance.ts.net -p 5432 -U "$DB_USER" -d nocodb-dev -tAc \
    "update nc_base_users_v2 set roles='$R' where base_id='$BASE_ID' and fk_user_id=(select id from nc_users_v2 where email='$E');" >/dev/null
done

cat > $OUT <<EOF
export API=$API
export OWN_TOK=$OWN_TOK
export EDI_TOK=$EDI_TOK
export CRE_TOK=$CRE_TOK
export BASE_ID=$BASE_ID
export T1_ID=$T1_ID
export T1_TITLE=$T1_TITLE
export T2_ID=$T2_ID
export T2_TITLE=$T2_TITLE
export T3_ID=$T3_ID
export T3_TITLE=$T3_TITLE
export T4_ID=$T4_ID
export T4_TITLE=$T4_TITLE
export OWNER=$OWNER
export EDITOR=$EDITOR
export CREATOR=$CREATOR
export TS=$TS
EOF
echo "env file: $OUT"
