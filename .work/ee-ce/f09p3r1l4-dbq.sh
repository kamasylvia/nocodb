#!/usr/bin/env bash
# f09p3r1l4-dbq.sh — lane4 只读 DB 探针: 源表 updated_at 物理帧定标
# 红线: 仅 nocodb-dev; 只读 SELECT; 凭证运行时 Infisical 拉取不落盘
set -euo pipefail
TABLE_NAME="$1"
ROW_TITLE="$2"
HOST="qnap.elf-balance.ts.net"
DB="nocodb-dev"   # 严禁 nocodb
set -a; eval "$(awk '/^\[infisical\]/{f=1;next}/^\[/{f=0}f' ~/.agents/config.toml | sed 's/[[:space:]]*#.*//; s/[[:space:]]*=[[:space:]]*/=/; /^[[:space:]]*$/d')"; set +a
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
[ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || { echo "FAIL: no creds"; exit 1; }

uv run --quiet --with "psycopg[binary]" python3 - "$HOST" "$DB_PORT" "$DB_USER" "$DB_PASSWORD" "$DB" "$TABLE_NAME" "$ROW_TITLE" <<'PY'
import sys, psycopg
host, port, user, pwd, db, table, title = sys.argv[1:8]
with psycopg.connect(host=host, port=port, user=user, password=pwd, dbname=db, connect_timeout=10) as c:
    with c.cursor() as cur:
        cur.execute("SELECT CURRENT_SETTING('timezone')")
        print("db timezone:", cur.fetchone()[0])
        cur.execute("SELECT table_schema FROM information_schema.tables WHERE table_name=%s", (table,)); print("schema:", cur.fetchone());
        cur.execute("SELECT data_type FROM information_schema.columns WHERE table_name=%s AND column_name='updated_at'", (table,))
        r = cur.fetchone()
        print("updated_at column type:", r[0] if r else "MISSING")
        cur.execute(f'SELECT id, \"Title\" AS title, created_at::text, updated_at::text FROM "ppt3trsql55h1a0"."{table}" ORDER BY id')
        for row in cur.fetchall():
            mark = " <== probe row" if title and row[1] == title else ""
            print("row:", row, mark)
        cur.execute("SELECT now()::text, localtimestamp::text")
        print("db now() (tz-aware, local):", cur.fetchone())
PY
echo "dbq done"
