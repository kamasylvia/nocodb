#!/bin/bash
# F03 R2 lane3 setup: users + base + table. Dev DB = nocodb-dev only.
set -u
API=http://localhost:8080
PG="/opt/homebrew/opt/libpq@18/bin/psql"
DB="postgresql://postgres:postgres@qnap.elf-balance.ts.net:5432/nocodb-dev"
OUT=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f03r2l3-env.sh

OWNER_EMAIL="lane3.owner.r2@test.local"
EDITOR_EMAIL="lane3.editor.r2@test.local"
CREATOR_EMAIL="lane3.creator.r2@test.local"
PW="Test1234!pass"

sign() { # email -> token (signup if needed, then signin)
  local email=$1
  curl -s -m 15 -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$PW\"}" | jq -r '.token // empty' > /tmp/sg_$$.json
  local t
  t=$(curl -s -m 15 -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$PW\"}" | jq -r '.token // empty')
  echo "$t"
}

OWNER_TOKEN=$(sign $OWNER_EMAIL)
echo "owner token len: ${#OWNER_TOKEN}"

# promote owner to super in DB (before signin use)
$PG "$DB" -tAc "update nc_users_v2 set roles='super' where email='$OWNER_EMAIL';" >/dev/null
OWNER_TOKEN=$(sign $OWNER_EMAIL)
echo "owner token len after promote: ${#OWNER_TOKEN}"
[ -z "$OWNER_TOKEN" ] && { echo "FAIL: owner token"; exit 1; }

# create base
BASE=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' -d '{"title":"f03r2l3-base"}')
BASE_ID=$(echo "$BASE" | jq -r '.id // empty')
echo "base: $BASE_ID"
[ -z "$BASE_ID" ] && { echo "$BASE"; exit 1; }

# create two tables
T1=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/$BASE_ID/tables -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"table_name":"Alpha","columns":[{"column_name":"Name","uidt":"SingleLineText"}]}')
T1_ID=$(echo "$T1" | jq -r '.id // empty')
echo "table Alpha: $T1_ID"
T2=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/$BASE_ID/tables -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"table_name":"Beta","columns":[{"column_name":"Name","uidt":"SingleLineText"}]}')
T2_ID=$(echo "$T2" | jq -r '.id // empty')
echo "table Beta: $T2_ID"

# editor + creator signup
EDITOR_TOKEN=$(sign $EDITOR_EMAIL)
CREATOR_TOKEN=$(sign $CREATOR_EMAIL)
echo "editor token len: ${#EDITOR_TOKEN}; creator token len: ${#CREATOR_TOKEN}"

# invite into base
INV1=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/$BASE_ID/users -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EDITOR_EMAIL\",\"roles\":\"editor\"}")
INV2=$(curl -s -m 15 -X POST $API/api/v2/meta/bases/$BASE_ID/users -H "xc-auth: $OWNER_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$CREATOR_EMAIL\",\"roles\":\"creator\"}")
echo "invite editor: $(echo $INV1 | head -c 120)"
echo "invite creator: $(echo $INV2 | head -c 120)"

# re-signin to get base roles
EDITOR_TOKEN=$(sign $EDITOR_EMAIL)
CREATOR_TOKEN=$(sign $CREATOR_EMAIL)

cat > "$OUT" <<EOF
API=$API
PG="$PG"
DB="$DB"
OWNER_EMAIL=$OWNER_EMAIL
EDITOR_EMAIL=$EDITOR_EMAIL
CREATOR_EMAIL=$CREATOR_EMAIL
PW='$PW'
OWNER_TOKEN=$OWNER_TOKEN
EDITOR_TOKEN=$EDITOR_TOKEN
CREATOR_TOKEN=$CREATOR_TOKEN
BASE_ID=$BASE_ID
T1_ID=$T1_ID
T2_ID=$T2_ID
EOF
echo "env written: $OUT"
