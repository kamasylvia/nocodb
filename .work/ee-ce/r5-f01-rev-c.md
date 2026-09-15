# r5-f01-rev-c.md — 第 5 路交叉面复审（R5, F01）

## PASS

### 1. 安全
- 全 diff（10 tracked 文件, +189/−40）+ 3 个未跟踪文件无凭证；AGENTS.md 仅占位符 `pg://<host>?u=<user>&p=<pass>&d=nocodb-dev`，无真实值
- 错误回显面：`UniqueConstraintViolationError({value, fieldName})` 仅回显用户提交值 + 列标题/表单 label，无 SQL/stack/host/内部路径泄漏；normalize/sqlite 拒绝的 NcError 消息均为静态串；MysqlClient DDL 走 `??` 参数化
- f01-e2e.sh 测试账号口令在 `.work/`（gitignored），符合 AGENTS.md §3.1 一次性 dev 账号豁免

### 2. 一致性
- `[CE-EE]` 标记逐 hunk 覆盖全部 10 个 tracked 改动文件，含 R3/R4 新段（tables.service UUID 强制+readonly 双标记、sqlite 双值判定、mysql PRIMARY 透传、空串 value 回退、error handler 全部 R2/R3 块）
- `isEeUI` 未动：`packages/nc-gui/utils/ncUtils.ts:1` 仍 `false`，不在 diff
- gitignore 生效：`git check-ignore` 实测命中 `.work/`（:139）与 `packages/noco-integrations/packages/`（:141）；git status 无 .work 泄漏
- Api.ts 不在列表：`packages/nocodb-sdk/src/lib/Api.ts` 无 diff（R1 还原后未再污染）

### 3. 测试基建（全实跑）
- `npx jest --listTests` → 恰 1 文件（uniqueConstraintHelpers.Fork.spec.ts）
- jest：**14/14** pass（12.3s）
- vitest（nc-gui 定向）：**8/8** pass（9.56s）
- `npx tsc --noEmit`（packages/nocodb）：**exit 0**，无输出

### 4. 运行时红线
- 脚本目标面：dev-backend.sh / f01-e2e.sh 硬编码 `qnap.elf-balance.ts.net` + `nocodb-dev`；r4a_pgidx.py 全 env 注入无硬编码；r4a_api.sh 仅 localhost:8080 + dev 测试账号
- 运行中 server（PID 74959）env 实测：`NC_DB=pg://qnap.elf-balance.ts.net:5432?u=***&p=***&d=nocodb-dev` ✓；`/api/v1/health` OK，未认证 probe 401 正常
- e2e trap 幂等：EXIT trap cleanup 带 `|| true` + 双空值守卫，与步骤 7 显式删除叠加不炸

### 5. 文档同步
- AGENTS.md §3.2 三条齐全：ts-jest `isolatedModules`（L67）、Infisical `--domain`（L68）、上游测试噪音（L69）
- GOAL-STATE.md：更新时间 2026-09-12、R5 会审进行中、计数 0/3 —— 与实际一致（本路即 R5 之一）
- TODO.md：F01 未勾（未 pass，准确）；无完成未勾项

### 6. 终局清单（模拟 F01 pass + commit 前最后检查）
应提交 13 文件 = 10 tracked 修改（.gitignore、jest.config.js、EditOrAdd.vue、useEeConfig.ts、BaseModelSqlv2.ts、MysqlClient.ts、uniqueConstraintErrorHandler.ts、uniqueConstraintHelpers.ts、columns.service.ts、tables.service.ts）+ 3 新增（AGENTS.md、packages/nc-gui/test/unique-constraint-helpers.test.ts、packages/nocodb/src/helpers/uniqueConstraintHelpers.Fork.spec.ts）。git status 无第 14 项；无应删未删临时物（logs/symlink 均在 ignored 路径下）。

## 备注（非 error，不入计数）
- backend.log 末尾有 401 ERR_AUTHENTICATION_REQUIRED 堆栈，为未认证请求的运行时日志噪音，非代码 console.error 残留
- 已裁 backlog（表创建内联 UNIQUE vs partial 分叉等）维持不修判定，本路复核无新反证
