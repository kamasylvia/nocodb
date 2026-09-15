#!/bin/bash
# request helper: signin-on-401 retry. Usage: r4a_api.sh METHOD URL [JSON_BODY] [DATAFILE]
R4A_DIR=/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce
signin() {
  XC_AUTH=$(curl -s -X POST http://127.0.0.1:8080/api/v2/auth/user/signin -H 'Content-Type: application/json' \
    -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])' 2>/dev/null)
  echo -n "$XC_AUTH" > "$R4A_DIR/.r4a_token"
}
XC_AUTH=$(cat "$R4A_DIR/.r4a_token" 2>/dev/null)
[ -z "$XC_AUTH" ] && signin
METHOD=$1; URL=$2; BODY=$3; DATAFILE=$4
for attempt in 1 2 3; do
  if [ -n "$DATAFILE" ]; then
    RESP=$(curl -s -w '\n%{http_code}' -X "$METHOD" "$URL" -H "xc-auth: $XC_AUTH" -H 'Content-Type: application/json' --data-binary @"$DATAFILE")
  elif [ -n "$BODY" ]; then
    RESP=$(curl -s -w '\n%{http_code}' -X "$METHOD" "$URL" -H "xc-auth: $XC_AUTH" -H 'Content-Type: application/json' -d "$BODY")
  else
    RESP=$(curl -s -w '\n%{http_code}' -X "$METHOD" "$URL" -H "xc-auth: $XC_AUTH")
  fi
  CODE=$(echo "$RESP" | tail -1)
  if [ "$CODE" = "401" ] && [ $attempt -lt 3 ]; then signin; XC_AUTH=$(cat "$R4A_DIR/.r4a_token"); continue; fi
  echo "$RESP" | sed "$d"
  echo "__HTTP__=$CODE"
  exit 0
done
