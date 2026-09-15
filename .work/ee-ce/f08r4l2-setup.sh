#!/bin/zsh
B=http://localhost:8080
P=f08r4l2
sfx=$1  # unique suffix to avoid reuse across runs
mk() { # email pass
  curl -s -X POST $B/api/v1/auth/user/signup -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"Test1234!\"}"
}
si() { # email pass -> token
  curl -s -X POST $B/api/v1/auth/user/signin -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("token") or d.get("refresh_token") or d)'
}
echo "SIGNUP_OWNER: $(mk $P-owner$sfx@t.io)"
echo "SIGNUP_WS: $(mk $P-wsv$sfx@t.io)"
echo "SIGNUP_ED: $(mk $P-ed$sfx@t.io)"
echo "SIGNUP_VW: $(mk $P-vw$sfx@t.io)"
echo "SIGNUP_IN: $(mk $P-in$sfx@t.io)"
echo "SIGNUP_NA: $(mk $P-na$sfx@t.io)"
