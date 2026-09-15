#!/usr/bin/env bash
# lane3 F03 test env — creds pulled at runtime; db hardcoded nocodb-dev
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
eval "$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^(DB_HOST|DB_PORT|DB_USER|DB_PASSWORD)=' | sed 's/^/export /')"
export PGPASSWORD="$DB_PASSWORD"
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
q() { "$PSQL" -h qnap.elf-balance.ts.net -p 5432 -U "$DB_USER" -d nocodb-dev -At -c "$1"; }
API=http://localhost:8080
