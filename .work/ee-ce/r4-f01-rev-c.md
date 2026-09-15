# r4-f01-rev-c — 第 4 轮交叉面复审报告（第 5 路）

- 日期: 2026-09-12
- 对象: git status 全量（10 tracked 改动 + 3 untracked）
- 方法: 全 diff 读码 + handler 全文终核 + 测试实测 + 运行进程 env 实测 + git check-ignore 实测

## 裁决: PASS（0 必修 error；3 条文档增补建议，非违反）

## 实测证据

1. 安全:
   - 全 diff + 2 个新 spec 文件 grep 凭证模式（password/secret/token/PAT/api_key）0 命中
   - 错误回显面终核（uniqueConstraintErrorHandler.ts 全文 1092 行）: UniqueConstraintViolationError 的 value 只来自 DB error detail 或用户提交 payload 本身（自输入回显，无敏感聚合）；R2 已移除 `errorString.includes('23505')` 自由文本扫描，仅结构化 code/errno 判定；R2/R3 的 `return` 透传语义正确（原错误由外层 `throw e` 继续）
2. 一致性:
   - `[CE-EE]` 标记全覆盖: diff 全部 10 文件逐块核对均有标记；2 个新 spec 各带标记
   - `isEeUI` 不在 diff（grep 0 命中）；ncUtils.ts 未动
   - `.gitignore` 双路径实测生效: `git check-ignore -v` 命中 `.work/ee-ce/TASK.md`(:139) 与 `packages/noco-integrations/packages/core`(:141)
   - Api.ts / nocodb-sdk 不在改动列表
3. 测试基建（实测）:
   - `npx jest --listTests` = 1（仅 uniqueConstraintHelpers.Fork.spec.ts）
   - jest Fork spec 13/13 pass
   - vitest F01 suite（unique-constraint-helpers.test.ts）8/8 pass
   - `npx tsc --noEmit` 0 输出 0 error
4. 运行时红线（实测）:
   - dev-backend.sh: 仅 `qnap.elf-balance.ts.net` + `nocodb-dev`；凭证运行时 Infisical 拉取不落盘（日志落 .work/ 已 ignore）
   - f01-e2e.sh: 仅 127.0.0.1；trap cleanup 幂等核过（`${CREATED_BASE:-}` 防 set -u、`|| true` 容错、第 7 步显式删后 trap 重删 404 被吞）
   - 运行中 server（rspack pid 74959 → main.js pid 3082）env 实测: `NC_DB=pg://qnap.elf-balance.ts.net:5432?...&d=nocodb-dev`（密码面已脱敏核验）✓
5. 文档同步:
   - GOAL-STATE（更新时间 2026-09-12, R4 会审中, 计数 0/3, LOCK active）与实际一致；R1-R3 修复清单与 diff 逐块对应，无 diff 外未记录改动、无记录外未落 diff 改动
   - TODO.md F01 未勾（未 pass，正确）；AGENTS.md §1 F01「待做」（pass 后更新，可接受）

## issues（全部为建议级，非违反）

1. AGENTS.md:§3.2:坑缺失:ts-jest + TS 5.8 language-service 崩溃需 `isolatedModules: true`（GOAL-STATE R1#8 与 jest.config.js 注释有，AGENTS.md §3.2 无）:建议 §3.2 增补一行
2. AGENTS.md:§3.1/§3.2:坑缺失:Infisical CLI `infisical login` 需显式 `--domain $INFISICAL_URL`，全局 §2.3.2 流程缺此参（GOAL-STATE R1 环境备注有，项目 AGENTS.md 无）:建议 §3.2 增补（全局正本修订另待用户）
3. AGENTS.md:§3 测试段:坑缺失:上游自带失败套件 `test/pwa-self-destroying.test.ts`（import 已删的 `pwa.config`，commit 867b407ba2 遗留）→ 全量 vitest 恒 1 failed；另 `formula-url-xss.test.ts` 全量并发下偶发抖动（单跑 5/5 过）。两者均非本 fork 引入。GOAL-STATE R2 backlog 已记，AGENTS.md 无 caveat:建议 §3 注明，避免后续会审把全量 vitest 非全绿误判为 F01 error
