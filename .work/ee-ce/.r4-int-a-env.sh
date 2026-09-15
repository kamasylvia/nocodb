#!/bin/bash
# r4-int-a test env: runtime-pull DB creds (nocodb-dev only), fresh xc-auth token
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null </dev/null)
while IFS='=' read -r k v; do case "$k" in DB_HOST) export PGHOST=qnap.elf-balance.ts.net;; DB_PORT) export PGPORT=$v;; DB_USER) export PGUSER=$v;; DB_PASSWORD) export PGPASSWORD=$v;; esac; done < <(
  infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" </dev/null 2>/dev/null | grep -i '^DB_'
)
export PGDATABASE=nocodb-dev
export XC_AUTH=$(curl -s -X POST http://127.0.0.1:8080/api/v2/auth/user/signin -H 'Content-Type: application/json' -d '{"email":"f01e2e@ce-ee.local","password":"F01e2e!pass1"}' | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
