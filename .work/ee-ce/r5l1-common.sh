# 运行时拉凭证，不落盘密码。⚠️ Infisical KDL 的 DB_NAME secret 值为 "nocodb"（生产库名），
# 绝不可直接使用 —— 本仓红线：只许 nocodb-dev。此处显式硬编码库名。
set -a; . ~/.zcode/.env; set +a
TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null)
eval "$(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api" 2>/dev/null | grep -E '^DB_(HOST|PORT|USER|PASSWORD)=' | sed 's/^/export /')"
PSQL=/opt/homebrew/opt/libpq@18/bin/psql
DEVDB=nocodb-dev
