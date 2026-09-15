#!/bin/bash
# R8 lane3 test env — fresh users (local dev-only test accounts)
API=http://localhost:8080
OWN=f02r8l3own@test.local
EDT=f02r8l3edt@test.local
CRT=f02r8l3crt@test.local
PW='Lane3R8!x'
sign(){ curl -s -X POST $API/api/v2/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}"; }
signin(){ curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}"; }
echo "signup own: $(sign $OWN | head -c 120)"
echo "signup edt: $(sign $EDT | head -c 120)"
echo "signup crt: $(sign $CRT | head -c 120)"
OT=$(signin $OWN | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
ET=$(signin $EDT | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
CT=$(signin $CRT | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "OT len: ${#OT}  ET len: ${#ET}  CT len: ${#CT}"
echo "$OT" > /tmp/f02r8l3_ot; echo "$ET" > /tmp/f02r8l3_et; echo "$CT" > /tmp/f02r8l3_ct
