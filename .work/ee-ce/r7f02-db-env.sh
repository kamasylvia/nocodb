# R7 F02 lane5 local test helper — DB creds pulled at runtime from Infisical (never hardcoded)
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
eval $(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^(DB_HOST|DB_PORT|DB_USER|DB_PASSWORD)=' | sed 's/^/export /')
PSQL="/opt/homebrew/opt/libpq@18/bin/psql"
export PGURL="postgresql://$DB_USER:$DB_PASSWORD@qnap.elf-balance.ts.net:5432/nocodb-dev"
