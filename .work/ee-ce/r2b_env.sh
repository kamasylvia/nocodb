#!/bin/zsh
# r2b_env.sh — 运行时拉 DB 凭证 export（不落盘），供 r2b_pgq.py 用
set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
while IFS='=' read -r k v; do
  case "$k" in
    DB_USER) export PGUSER="$v";;
    DB_PASSWORD) export PGPASSWORD="$v";;
    DB_PORT) export PGPORT="$v";;
  esac
done <<< "$SECRETS"
export PGHOST="qnap.elf-balance.ts.net"
export PGDATABASE="nocodb-dev"
[ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] || { echo "FAIL: no db creds" >&2; exit 1; }
