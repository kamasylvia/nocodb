# r4-f05-rev-c — F05 R4 第 5 路（交叉面复审）报告

## issues

1. `packages/nc-gui`（仓内无 vitest 配置）:`test/base-variables-acl.test.ts:2` + `test/unique-constraint-helpers.test.ts:2`：裸 `npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` 两文件全挂（`Error: Cannot find module '~/lib/acl'`；补 alias 后 `ReferenceError: describe is not defined`）——nc-gui 无任何 vitest.config（仅 nuxt.config.ts/uno.config.ts），`~` alias 与 globals 均未配置：建议仓内提交 `packages/nc-gui/vitest.config.ts`（resolve.alias `~`/`@` → 包根 + `test.globals: true`）或测试文件改显式 `import { describe, it, expect } from 'vitest'` + 相对路径导入。实测旁证：用临时配置（`.work/ee-ce/vitest.config.mjs`，alias+globals，gitignored）跑同两文件 → 10/10 全过（F05 2 + unique 8），测试代码本身无 bug，纯测试基建缺口——「vitest 实跑全过」在已提交的仓树上不可复现。

2. `.work/TODO.md:8`:F05 行写「R3 会审进行中」与实际不符（`.work/ee-ce/GOAL-STATE.md` 已记「F05-R4 会审 5 路运行中」）：建议同步为 R4 进行中；违反「修订=原子同步」commit guard（TODO 是唯一状态判据源）。

## 实测覆盖（无发现项证据）

- 安全全链路（.work/ee-ce/f05r4c_sec_chain.sh，nocodb-dev，严禁生产库未触碰）：secret 创建 → uv pg8000 直查 `nc_base_variables.value` = `U2FsdGVkX1/...` 密文（≠明文 marker、不含 marker 子串）→ list 掩码 OK → 单条 get 解密回读 OK（含二次读稳定性）→ base 删除后 DB 0 残留 → 全 PASS。
- 加密 key 不入 git：`git grep dev-only-ce-ee-encrypt-key` 0 命中；dev-backend.sh 含 dev key 但 `git check-ignore` 确认 `.work/` 被 ignore（.gitignore:139，F01 已提交）；AGENTS.md 仅记 env 名不记值。
- tsc：`npx tsc --noEmit` exit 0（dev server 侧 `[type-check] no errors found` 双证）。
- jest：`npx jest` 26/26（2 suites：uniqueConstraintHelpers.Fork 14 + baseVariableValidators.Fork 12；现有 testRegex Fork 桶直接命中新 spec，故 jest.config 本轮无需改动，非缺失）。
- 一致性：`git diff --name-only | grep -Ei "Api\.ts|isEeUI|nocodb-sdk"` 0 命中（Api.ts/isEeUI/sdk 未动）；[CE-EE] 标记覆盖全部 14 个改动代码文件（lang JSON 无法带注释，沿 F01 先例豁免）；en/zh-Hans 新键全对齐、无重复 JSON key；`title.baseVariables` 等引用键 CE 已有。
- 文档：AGENTS.md §3.2（构建与网络坑）已含 `NC_CONNECTION_ENCRYPT_KEY` 约定行（AGENTS.md:70）。
- status 清单核对：新增 5 文件 = service/controller/validators/validators-spec + FE test（「组件」以改写 stub `Variables/index.vue` 承担，与 GOAL-STATE F05 实现记录一致，无缺失）；修改 12 文件与 GOAL-STATE 一致；orchestrator 清单中 jest.config/.gitignore 两项本轮确无改动需求（F01 commit 744d31618b 已覆盖：Fork testRegex 桶 + `.work/` ignore），非缺失。
- 环境注：复审期间 dev server 因 rspack 重启竞态失听，已按 §8.2 同服务重启例外恢复（sandbox 外启动后恢复监听，404=正常）；未影响其它路共享状态的持久数据。
