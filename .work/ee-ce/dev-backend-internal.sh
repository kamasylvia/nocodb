#!/bin/bash
# [CE-EE] 后端直跑脚本（内盘副本版，2026-09-15）
# 背景：外置盘（UNITEK）文件缓存冷后 node_modules 随机读为小时级，故运行时副本放内置 SSD。
# 用法: .work/ee-ce/dev-backend-internal.sh [start|stop|status]
# 同步：源码修改后在 UNITEK 提交，然后 rsync 到 ~/.nocodb-run 并重启本脚本（热修流程）。
set -euo pipefail
RUN=/Users/kamasylvia/.nocodb-run
LOG=/tmp/nocodb-internal.log

case "${1:-start}" in
  stop)
    pkill -f "$RUN/packages/nocodb/dist/main.js" 2>/dev/null && echo "stopped" || echo "not running"
    ;;
  status)
    pgrep -f "$RUN/packages/nocodb/dist/main.js" >/dev/null && echo "running" || echo "not running"
    ;;
  start|*)
    pgrep -f "$RUN/packages/nocodb/dist/main.js" >/dev/null && { echo "already running"; exit 0; }
    # [CE-EE] 2026-09-20: agents/agents/.env 废止（用户迁移 config.toml [infisical] 为唯一真相源）——
    # 改从 config.toml 注入身份 + PROJECT_ID_KDL，.zcode/.env 软链不再依赖
    set -a; eval "$(awk '/^\[infisical\]/{f=1;next}/^\[/{f=0}f' "$HOME/.agents/config.toml" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*=[[:space:]]*/=/; /^[[:space:]]*$/d')"; set +a
    # [CE-EE] 2026-09-20: INFISICAL_PROJECT_ID_KDL 自 ~/.zcode/.env 迁至
    # ~/.agents/config.toml [infisical] 段（全局 AGENTS §2.3.0）——缺则补载
    if [ -z "${INFISICAL_PROJECT_ID_KDL:-}" ] && [ -f "$HOME/.agents/config.toml" ]; then
      eval "$(awk '/^\[infisical\]/{f=1;next}/^\[/{f=0}f' "$HOME/.agents/config.toml" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*=[[:space:]]*/=/; /^[[:space:]]*$/d')"
    fi
    export INFISICAL_DOMAIN="$INFISICAL_URL"
    TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --plain 2>/dev/null)
    eval $(infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env "$INFISICAL_ENVIRONMENT" --recursive --plain 2>/dev/null | grep -E "^DB_(USER|PASSWORD|PORT)=" | sed 's/^/export /')
    cd "$RUN/packages/nocodb"
    NODE_ENV=development NC_DISABLE_TELE=true ENTRYPOINT=src/run/docker \
      NC_DB="pg://qnap.elf-balance.ts.net:${DB_PORT:-5432}?u=${DB_USER}&p=${DB_PASSWORD}&d=nocodb-dev" \
      NC_CONNECTION_ENCRYPT_KEY="dev-only-ce-ee-encrypt-key-0f1e2d3c" \
      nohup node "$RUN/packages/nocodb/dist/main.js" > "$LOG" 2>&1 &
    echo "started pid=$! (log: $LOG)"
    ;;
esac
