# lane3 helper lib — source after lane3-env + lane3-ids
PW='Lane3F03!x'; BID=${BID:-p2ul0ca5fiabj7k}
lg_signin() { curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | jq -r .token; }
OT=$(lg_signin lane3-f03-owner@t.local); ET=$(lg_signin lane3-f03-editor@t.local); CT=$(lg_signin lane3-f03-creator@t.local)
PR=/api/v2/meta/bases/$BID/permissions
lg_code() { curl -s -o /tmp/lane3-body -w '%{http_code}' "$@"; }
lg_body() { cat /tmp/lane3-body; }
lg_rowid() { curl -s "$API/api/v2/tables/$1/records?where=(Name,eq,$2)" -H "xc-auth: $OT" | jq '.list[0].Id // 0'; }
lg_seed() { lg_code -X POST $API/api/v2/tables/$T2/records -H "xc-auth: $OT" -H 'Content-Type: application/json' -d "{\"Name\":\"$1\"}" >/dev/null; }
lg_gid() { curl -s $API$PR -H "xc-auth: $OT" | jq -r "[.[]|select(.permission==\"$1\")]|.[0].id // \"none\""; }
lg_chk() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS [$3] $1"; else echo "FAIL[exp=$2 got=$3] $1  body=$(lg_body|head -c 160)"; F=$((F+1)); fi }
