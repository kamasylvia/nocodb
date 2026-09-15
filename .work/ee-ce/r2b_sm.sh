#!/bin/zsh
# r2b_sm.sh — T2 状态机 DB 中间态补抓（自足：env + 等 server + 每步验证）
set -u
cd /Volumes/UNITEK/Documents/Development/nocodb
source .work/ee-ce/r2b_env.sh
PGPY="$PWD/.work/ee-ce/r2b_pgq.py"

# wait for server: signin succeeding is the real readiness signal
for i in $(seq 1 60); do
  TOKEN=$(signin 2>/dev/null)
  [ ${#TOKEN} -gt 100 ] && break
  sleep 5
done
[ ${#TOKEN:-} -gt 100 ] || { echo "SERVER NOT READY (signin never succeeded)"; exit 1; }
echo "server ready, token_len=${#TOKEN}"

signin() { curl -s -X POST http://127.0.0.1:8080/api/v1/auth/user/signin -H "Content-Type: application/json" -d '{"email":"f05r2b@ce-ee.local","password":"F05r2b!pass9"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"; }
TOKEN=$(signin)
BASEID=ptmmthnyxqp3paf

q() { uv run --with pg8000 python3 "$PGPY" "SELECT type, left(value,35) AS vh, length(value) AS vl FROM nc_base_variables WHERE key='SM2_VAR'"; }
g() { curl -s "http://127.0.0.1:8080/api/v2/meta/bases/$BASEID/variables/$VID" -H "xc-auth: $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); print('type='+str(d['type'])+' value='+repr(d['value']))" 2>/dev/null; }
p() { curl -s -o /dev/null -w "%{http_code}" -X PATCH "http://127.0.0.1:8080/api/v2/meta/bases/$BASEID/variables/$VID" -H "xc-auth: $TOKEN" -H "Content-Type: application/json" -d "$1"; }

VID=bvg9cs1enimgeqza
echo "current: DB=$(q | tr -d '\n') API=$(g)"
echo "step3 PATCH value=beta2: http=$(p '{"value":"beta2"}')"
echo "  after: DB=$(q | tr -d '\n') API=$(g)"
echo "step4 PATCH type=text: http=$(p '{"type":"text"}')"
echo "  after: DB=$(q | tr -d '\n') API=$(g)"
echo "LIST=$(curl -s "http://127.0.0.1:8080/api/v2/meta/bases/$BASEID/variables" -H "xc-auth: $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); v=[x for x in d if x.get('key')=='SM2_VAR'][0]; print('type='+str(v.get('type'))+' value='+repr(v.get('value')))")"
