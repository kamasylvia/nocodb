#!/bin/zsh
# dev-backend.sh — 启动 nocodb 后端 dev server（外部 PG: nocodb-dev）
# 凭证运行时从 Infisical KDL 项目拉取，不落盘。
# 用法: .work/ee-ce/dev-backend.sh [start|stop|status]
set -euo pipefail
REPO="/Volumes/UNITEK/Documents/Development/nocodb"
PGHOST="qnap.elf-balance.ts.net"   # Infisical 里 DB_HOST=pg18 是 QNap 容器名，本机不可解析
PGPORT_KEY="DB_PORT"
DBNAME="nocodb-dev"                # 严禁用 nocodb（生产）

case "${1:-start}" in
  stop)
    pkill -f "rspack --config rspack.dev.config.js" 2>/dev/null
    pkill -f "rspack.js --config rspack.dev.config.js" 2>/dev/null
    pkill -f "packages/nocodb/dist/main.js" 2>/dev/null
    pkill -f "nocodb/dist/main.js" 2>/dev/null
    sleep 1
    pgrep -f "rspack\|dist/main.js" >/dev/null && echo "warn: processes may remain" || echo "stopped"
    exit 0;;
  status)
    pgrep -f "rspack.dev.config.js" >/dev/null && echo "running" || echo "not running"
    exit 0;;
esac

set -a; . ~/.zcode/.env; set +a
export INFISICAL_DOMAIN="$INFISICAL_URL"
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain --domain "$INFISICAL_URL" 2>/dev/null)
SECRETS=$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null)
DB_USER=""; DB_PASSWORD=""; DB_PORT="5432"
while IFS='=' read -r k v; do
  case "$k" in
    DB_USER) DB_USER="$v";;
    DB_PASSWORD) DB_PASSWORD="$v";;
    DB_PORT) DB_PORT="$v";;
  esac
done <<< "$SECRETS"
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || { echo "FAIL: 未取到 DB 凭证"; exit 1; }

export NODE_ENV=development NC_DISABLE_TELE=true ENTRYPOINT=src/run/docker
# [CE-EE] F05: dev encryption key for secret base variables (model silently
# stores plaintext without it). Local-only value — production must inject a
# real key via its own env management.
export NC_CONNECTION_ENCRYPT_KEY="dev-only-ce-ee-encrypt-key-0f1e2d3c"
export NC_DB="pg://${PGHOST}:${DB_PORT}?u=${DB_USER}&p=${DB_PASSWORD}&d=${DBNAME}"
cd "$REPO/packages/nocodb"
mkdir -p "$REPO/.work/ee-ce/logs"
echo "starting backend on :8080 → ${PGHOST}:${DB_PORT}/${DBNAME} (log: .work/ee-ce/logs/backend.log)"
nohup npx rspack --config rspack.dev.config.js > "$REPO/.work/ee-ce/logs/backend.log" 2>&1 &
echo "pid=$!"
