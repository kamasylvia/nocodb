#!/usr/bin/env zsh
# R8 lane1 F02 env setup — accounts, base, table, invites
set -u
API=http://localhost:8080
S=rl1$$   # random suffix
DBHOST=qnap.elf-balance.ts.net
PSQL="/opt/homebrew/opt/libpq@18/bin/psql"
set -a; . /tmp/f02-db-env.txt; set +a
export PGPASSWORD="$DB_PASSWORD"
DBURL="postgresql://$DB_USER@$DBHOST:$DB_PORT/nocodb-dev"

jqget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

OEMAIL="r8l1own_$S@example.com"; EPASS='Passw0rd!123'
EEMAIL="r8l1edt_$S@example.com"
CEMAIL="r8l1cre_$S@example.com"

echo "== signup x3"
for em in $OEMAIL $EEMAIL $CEMAIL; do
  R=$(curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$em\",\"password\":\"$EPASS\"}")
  echo "$em -> $(echo $R | head -c 120)"
done

echo "== psql promote owner to super (pre-signin)"
$PSQL "$DBURL" -tAc "UPDATE nc_users_v2 SET roles='super' WHERE email='$OEMAIL' RETURNING email, roles;"

echo "== signin x3"
OSIGN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$OEMAIL\",\"password\":\"$EPASS\"}")
OTOK=$(echo $OSIGN | jqget "d['token']")
ESIGN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EEMAIL\",\"password\":\"$EPASS\"}")
ETOK=$(echo $ESIGN | jqget "d['token']")
CSIGN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$CEMAIL\",\"password\":\"$EPASS\"}")
CTOK=$(echo $CSIGN | jqget "d['token']")
echo "owner tok len: ${#OTOK} editor tok len: ${#ETOK} creator tok len: ${#CTOK}"
[ -z "$OTOK" ] && echo "FATAL owner signin" && exit 1

echo "== create base (v1)"
BASE=$(curl -s -X POST $API/api/v2/meta/bases/ -H "xc-auth: $OTOK" -H 'Content-Type: application/json' -d "{\"title\":\"r8l1_$S\"}")
BASEID=$(echo $BASE | jqget "d['id']")
echo "baseId=$BASEID"

echo "== create table with Title + Restricted + Normal"
TBL=$(curl -s -X POST $API/api/v1/db/meta/projects/$BASEID/tables -H "xc-auth: $OTOK" -H 'Content-Type: application/json' -d '{
  "table_name":"Sheet1","title":"Sheet1",
  "columns":[{"title":"Title","column_name":"title","uidt":"SingleLineText","meta":{}},
             {"title":"Restricted","column_name":"restricted","uidt":"SingleLineText","meta":{}},
             {"title":"Normal","column_name":"normal","uidt":"SingleLineText","meta":{}}]
}')
TBLID=$(echo $TBL | jqget "d['id']")
echo "tableId=$TBLID"
COLS=$(curl -s $API/api/v1/db/meta/tables/$TBLID -H "xc-auth: $OTOK")
RESC=$(echo $COLS | jqget "[c['id'] for c in d['columns'] if c['title']=='Restricted'][0]")
TITC=$(echo $COLS | jqget "[c['id'] for c in d['columns'] if c['title']=='Title'][0]")
echo "restrictedColId=$RESC titleColId=$TITC"

echo "== add editor+creator to base (v2 base-users)"
RU=$(curl -s -X POST $API/api/v2/meta/bases/$BASEID/users -H "xc-auth: $OTOK" -H 'Content-Type: application/json' -d "{\"email\":\"$EEMAIL\",\"roles\":\"editor\"}")
echo "invite editor: $(echo $RU | head -c 200)"
RU2=$(curl -s -X POST $API/api/v2/meta/bases/$BASEID/users -H "xc-auth: $OTOK" -H 'Content-Type: application/json' -d "{\"email\":\"$CEMAIL\",\"roles\":\"creator\"}")
echo "invite creator: $(echo $RU2 | head -c 200)"
# re-signin to refresh roles claim
ESIGN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$EEMAIL\",\"password\":\"$EPASS\"}")
ETOK=$(echo $ESIGN | jqget "d['token']")
CSIGN=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$CEMAIL\",\"password\":\"$EPASS\"}")
CTOK=$(echo $CSIGN | jqget "d['token']")
echo "editor tok len: ${#ETOK} creator tok len: ${#CTOK}"

cat > /tmp/f02-lane1-env.txt <<EOF
API=$API
OTOK=$OTOK
ETOK=$ETOK
CTOK=$CTOK
BASEID=$BASEID
TBLID=$TBLID
RESC=$RESC
TITC=$TITC
OEMAIL=$OEMAIL
EEMAIL=$EEMAIL
CEMAIL=$CEMAIL
EPASS=$EPASS
EOF
echo "ENV SAVED /tmp/f02-lane1-env.txt"
