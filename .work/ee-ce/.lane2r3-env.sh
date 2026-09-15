#!/bin/bash
SU=$(cat /Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/.lane2r3-suffix)
export OW="l2r3o$SU@t.io"; export ED="l2r3e$SU@t.io"; export CR="l2r3c$SU@t.io"
export PW='Passw0rd!123'
export API=http://localhost:8080
export WORK=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce
signin() {
  local resp
  resp=$(curl -s -X POST $API/api/v2/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}")
  echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("token") or d)' 
}
