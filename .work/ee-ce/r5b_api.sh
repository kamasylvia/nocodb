#!/bin/bash
BASE="http://127.0.0.1:8080"
TOKEN=$(curl -s -X POST "$BASE/api/v2/auth/user/signin" -H 'Content-Type: application/json' -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
H=(-H "xc-auth: $TOKEN" -H 'Content-Type: application/json')
PFX="f01r5b"
