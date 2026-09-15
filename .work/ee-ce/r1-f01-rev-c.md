# R1 F01 会审报告 — 第 5 路（交叉面：安全/一致性/测试基建）

> 隔离声明：未读任何 r*.md 报告；只读 TASK.md / 仓根 AGENTS.md / 源码 / 自跑命令输出。
> 日期：2026-09-12。diff 面 = 4 modified（EditOrAdd.vue / useEeConfig.ts / Api.ts / jest.config.js）+ 2 新 spec + .work 脚本（untracked）。

## 1. 安全

**PASS（diff 及新文件无凭证）**
- 逐行审 4 个 modified + 2 个新 spec：无 PAT/密码/secret/token 类字符串。grep 新 spec 文件 `password|secret|PAT|token` 零命中。
- `packages/noco-integrations/packages/core` 为 untracked symlink → `../core`（仓内相对路径，无外泄面）。

**PASS（uniqueConstraintErrorHandler 回显用户值 — API-only 场景可接受）**
- 回显点：`packages/nocodb-sdk/src/lib/error/nc-base.error.ts:67` — `` `${fieldName} field unique constraint violation. Value '${value}' already exists.` ``；value 来源 = PG 错误 detail 回显的**本次请求自己提交的 key**（`uniqueConstraintErrorHandler.ts:307-311,825-828`）或请求 payload（:317-338），非他人数据，无跨用户信息泄露。
- API-only JSON 响应，无 HTML sink；nc-gui 为 Vue 文本插值（自动转义）。上游 CE 既有代码，非本次 diff 改动面。维持上游行为，不判 issue。

**issue-1（低）：`.work/ee-ce/f01-e2e.sh:6-7`: 测试账号 email/password 明文落 .work，与仓根 AGENTS.md:71「凭证/密码永不入 .work 明文」字面冲突: 建议二选一——AGENTS.md 明确豁免「本地 throwaway 测试账号」，或脚本运行时生成密码。风险判定：`F01e2e!pass1` 12 位 4 字符类非弱口令，仅 127.0.0.1:8080 本地 dev、一次性账号，实际风险可接受。**

**issue-2（低）：`.gitignore`: `.work/` 未被 ignore（`git check-ignore .work` exit=1），整目录仅靠 untracked 状态防误提交，`git add -A` 即可把含明文测试密码与 logs 的 .work 整体入库: 建议 .gitignore 增加 `.work/` 条目（工具化红线，替代口头约定）。**

## 2. 一致性（vs 仓根 AGENTS.md）

**PASS（[CE-EE] 标记）**：本次 4 处 fork 修改全部带标记——useEeConfig.ts:160-163、EditOrAdd.vue:1512（`/* [CE-EE] F01 ... */`）、jest.config.js:8-9、两个新 spec 头部（Fork.spec.ts:8、nc-gui test:4）。

**PASS（isEeUI 未全局翻转）**：`packages/nc-gui/utils/ncUtils.ts:1` 仍 `isEeUI: boolean = false`，且不在 diff 内；EditOrAdd.vue 其余 showEEFeatures 消费点（:273,275,291,294）未动，仅 :1512 处换成 `!blockUnique`。

**PASS（静态）+ 待运行时审计（生产库）**：dev-backend.sh:7,9,35 host=`qnap.elf-balance.ts.net`、DBNAME=`nocodb-dev` 硬编码，DB 凭证运行时从 Infisical 拉（:20-32），无明文；f01-e2e.sh 只触 127.0.0.1:8080，不直连 DB。`.work/ee-ce/logs/backend.log` 未暴露 NC_DB/db 名 → 运行时实际连接串**待运行时审计**（静态无法证明）。

**issue-3（中，必修建议）：`packages/nocodb-sdk/src/lib/Api.ts:3076-8056`: 58 行与 F01 无关的再生 diff（ViewFieldsV3Type 404 文档注释 ×30、删 `@format uuid`、枚举加 `Channel`、`fk_base_section_id`/`fk_automation_section_id`/`blocked`/`blocked_reason`/`preferences` 改名/userId 参数）——非本 fork 刻意修改却混入 F01 工作区：① 违反 [CE-EE] 标记约定；② GOAL-STATE「F01 已实施改动」清单未列（文档与 git 实际不一致）；③ 属 sdk `generate:sdk` 副产物（nocodb-sdk/package.json:38），随 F01 提交会污染上游对照面: 建议 `git checkout -- packages/nocodb-sdk/src/lib/Api.ts` 还原；若确需保留，拆独立提交 + GOAL-STATE 补记来源。**

## 3. 测试基建

**PASS（jest testRegex 变更收敛）**
- `cd packages/nocodb && npx jest --listTests` → **恰好 1 个文件**：`src/helpers/uniqueConstraintHelpers.Fork.spec.ts`。
- src 下共 110 个 `*.spec.ts`，其中 109 个不匹配新 regex（既有 stub spec 未误纳）；`Integration.spec.ts`/`Source.spec.ts` 在 src 下 0 个 → 旧 regex 应得 0，新 regex delta = +1（仅 Fork spec），与预期完全一致。

**PASS（后端 Fork spec 实跑）**：`npx jest src/helpers/uniqueConstraintHelpers.Fork.spec.ts` → 11/11 passed（Test Suites 1 passed）。

**PASS（前端 vitest 独立运行）**：`cd packages/nc-gui && npx vitest run --config test/vite.config.ts test/unique-constraint-helpers.test.ts` → 8/8 passed（12.57s）；该文件**不在** vitest 的 8 个 EE-only skip 名单内，spec 断言与实现（`packages/nocodb/src/helpers/uniqueConstraintHelpers.ts` / `packages/nc-gui/utils/uniqueConstraintHelpers.ts`）消息模式逐条核对一致。

## 4. 后端全量单测抽查

**PASS**：`npx jest --listTests | wc -l` = **1**（非 0、非异常）；等于改动前 testRegex 应得数（0 个 Integration/Source）+ 1 个 Fork spec。

## 5. 文档同步

**PASS（TODO.md / GOAL-STATE 主体）**：TODO.md:7 F01 未勾（未 pass，正确）；GOAL-STATE.md:21-30 改动清单 1-6 项与 git diff 逐条对应，状态「R1 会审中」与实际一致。

**issue-4（低）：仓根 `AGENTS.md:49`: 测试说明仍写 testRegex `(Integration|Source)\.spec\.ts$`，与 jest.config.js 现值 `(Integration|Source|Fork)\.spec\.ts$` 不一致（文档滞后于已实施改动）: 同批更新为含 Fork 桶。**

**（并入 issue-3）GOAL-STATE.md:21-30**: 改动清单缺 Api.ts 一项，与 git 实际改动不一致；Api.ts 处置后同步。

## 6. 环境红线审计（静态）

**PASS（dev-backend.sh）**：无明文 DB 密码（:22-32 运行时 Infisical 拉取，仅内存传递）；host=`qnap.elf-balance.ts.net`（:7）；db=`nocodb-dev`（:9, :35）。

**PASS（f01-e2e.sh，DB 面）**：不直连 DB，仅 `BASE_URL=http://127.0.0.1:8080`（:5），无 DB host/db 名（N/A 即合规）。账号明文密码见 issue-1。

## 裁决结论

**无安全类 error；4 个 issue（1 中 3 低）。**
- issue-3（Api.ts 无关再生 diff 混入、无 [CE-EE] 标记、GOAL-STATE 漏记）建议**必修**：还原 Api.ts 或拆分提交并补文档——它是唯一会进入 commit 的脏面。
- issue-1/2/4 为低危建议项（.work 明文测试密码规则字面冲突 / .work 未入 .gitignore / AGENTS.md testRegex 滞后）。
- 测试基建全绿：jest 收敛 +1 文件（仅 Fork spec，109 stub 未误纳）、Fork spec 11/11、vitest 8/8 独立通过；isEeUI 未翻转；生产库红线静态合规（运行时待审计）。
