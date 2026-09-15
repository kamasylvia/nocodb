#!/bin/bash
# F02 R4 lane4 UI test data setup — f02r4l4-* users on nocodb-dev via :8080
set -e
API=http://localhost:8080
PW_O='F02r4l4-Owner!9'
PW_E='F02r4l4-Editor!9'
E_O=f02r4l4-owner@test.local
E_E1=f02r4l4-editor1@test.local
E_E2=f02r4l4-editor2@test.local
OUT=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f02r4l4-ctx.json

jq_val() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$2" 2>/dev/null <<<"$1"; }

# 1. signup all three
for u in "$E_O" "$E_E1" "$E_E2"; do
  code=$(curl -s -o /tmp/f02r4l4_su.json -w '%{http_code}' -X POST "$API/api/v1/auth/user/signup" \
    -H 'Content-Type: application/json' -d "{\"email\":\"$u\",\"password\":\"$PW_E\"}" || true)
  echo "signup $u -> $code"
done

# owner password may differ if pre-existing; try signin with owner pw
signin() { curl -s -X POST "$API/api/v1/auth/user/signin" -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}"; }

R_O=$(signin "$E_O" "$PW_O")
T_O=$(jq_val "$R_O" "d.get('token','')")
echo "owner token len: ${#T_O}"

# 2. create base
RB=$(curl -s -X POST "$API/api/v2/meta/bases/" -H "xc-token: $T_O" -H 'Content-Type: application/json' -d '{"title":"f02r4l4 base"}')
BID=$(jq_val "$RB" "d.get('id','')")
echo "base: $BID"

# 3. create table Name+Secret
RT=$(curl -s -X POST "$API/api/v2/meta/bases/$BID/tables" -H "xc-token: $T_O" -H 'Content-Type: application/json' \
  -d '{"table_name":"F02R4L4","columns":[{"column_name":"Name","uidt":"SingleLineText"},{"column_name":"Secret","uidt":"SingleLineText"}]}')
TID=$(jq_val "$RT" "d.get('id','')")
echo "table: $TID ; cols: $(jq_val "$RT" "','.join(c['title'] for c in d.get('columns',[]))")"

# 4. insert 2 records (flat body per AGENTS)
R1=$(curl -s -X POST "$API/api/v2/tables/$TID/records" -H "xc-token: $T_O" -H 'Content-Type: application/json' \
  -d '[{"Name":"row1","Secret":"alpha"},{"Name":"row2","Secret":"beta"}]')
echo "insert: $(echo "$R1" | head -c 200)"

# 5. invite editor1+editor2 as base editor
for e in "$E_E1" "$E_E2"; do
  RI=$(curl -s -X POST "$API/api/v2/meta/bases/$BID/users" -H "xc-token: $T_O" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$e\",\"roles\":\"editor\"}")
  echo "invite $e -> $(echo "$RI" | head -c 200)"
done

# 6. verify editor signin
R_E1=$(signin "$E_E1" "$PW_E")
T_E1=$(jq_val "$R_E1" "d.get('token','')")
echo "editor1 token len: ${#T_E1}"

cat > "$OUT" <<EOF
{"baseId":"$BID","tableId":"$TID","owner":"$E_O","ownerPw":"$PW_O","ownerToken":"$T_O","editor1":"$E_E1","editorPw":"$PW_E","editorToken":"$T_E1","editor2":"$E_E2"}
EOF
echo "ctx saved: $OUT"
