# AGENTS.md — nocodb CE-EE fork

> 工作区级约束。全局 `~/.zcode/AGENTS.md` 优先级更高；本文是项目补充。
> 交互语言：中文（caveman 压缩风格）。代码/commit/API 名保持原文。

## 1. 项目目标

在 NocoDB **CE**（community edition）源码上实现 **EE**（enterprise edition）功能。本仓为 nocodb/nocodb 上游的 fork，目标功能清单（暂定，可能扩展）：

| # | 功能 | EE feature flag (`PlanFeatureTypes`) | 状态 |
|---|---|---|---|
| F01 | Unique values only | `FEATURE_UNIQUE` | **pass**（commit 744d3161） |
| F02 | Edit field permissions | `FEATURE_TABLE_AND_FIELD_PERMISSIONS` | **pass**（2026-09-14，实现 4b26d7a23f + 七轮修复终 ca6c81f5a6） |
| F03 | Data permissions | `FEATURE_TABLE_AND_FIELD_PERMISSIONS` | **pass**（2026-09-16，R4/R5/R6 连击 3/3，实现 7b10716231 + 修复链终 51b9637b84） |
| F04 | Manage Syncs | `FEATURE_SYNC` | **pass**（2026-09-17，R3/R4/R5 连击 3/3，实现 2fd09efccf + 修复链终 b6c95cb3ac） |
| F05 | Variables (base variables) | `FEATURE_BASE_VARIABLES` | **pass**（commit 6ab23da0） |
| F06 | Docs Permissions | `FEATURE_DOCUMENT_PERMISSIONS` | **fork 限制裁剪**（2026-09-17 裁定：Docs 本体 CE 零存在；可逆，f06-research.md 三选项） |
| F07 | Manage Snapshots | `FEATURE_SCHEDULED_SNAPSHOTS` | **pass**（commit bc409929da） |
| F08 | Base Type - Private | `FEATURE_PRIVATE_BASES` | **pass**（实现 6aea3db097 + 四轮修复，终 e737f8f3ec） |
| F09 | Sync data (table/custom sync) | `FEATURE_TABLE_SYNC` / `FEATURE_CUSTOM_SYNC` | **P1 pass**（2026-09-18，R9/R10/R11 连击 3/3，实现 71896a841f + 修复链终 5e3d736b2a；P2–P4 backlog） |
| F10 | Create Dashboard | `LIMIT_DASHBOARD_PER_WORKSPACE` | **pass**（commit ab31f60fe3） |

## 2. 架构关键认知（改码前必读）

**双仓 overlay 架构**：NocoDB 官方 = CE 仓 + 私有 EE 仓。EE 仓把 `src/ee/` 树覆盖到 `packages/nocodb/src/` 之上（jest `moduleNameMapper` 先解析 `src/ee/`，见 `packages/nocodb/jest.config.js`）。**本仓 `src/ee` 不存在**，CE 内全部是 stub。实现 EE 功能 = 用自己的实现替换这些 stub（不引入官方 EE 代码）。

核心 gating 文件：

- 前端总开关：`packages/nc-gui/utils/ncUtils.ts:1` — `isEeUI = false`（编译期常量，勿全局翻转，会激活大量依赖 EE 后端的 UI 路径）
- 前端 paywall 中枢：`packages/nc-gui/composables/useEeConfig.ts` — 各 feature gate（`blockSync` / `blockPrivateBases` / `blockDocumentPermissions` / `blockAddNewDashboard` …）硬编码 blocked；升级弹窗回调为 no-op。**本 fork 已解 gate**：`blockUnique`（F01）/ `blockBaseVariables`（F05）/ `blockSnapshots`（F07）= false
- stub UI 组件（渲染 `<NcSpanHidden />` 空壳）：`packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`、`.../base/Variables/index.vue`、`packages/nc-gui/components/project/Sync/index.vue`、`.../settings/Permissions.vue`、`.../settings/DocsPermissions.vue` 等
- stub 后端 model：`src/models/Permission.ts`（`list()→[]`、`isAllowed()→true`）、`src/models/BaseVariable.ts`、`src/models/Dashboard.ts`、`src/db/BaseModelSqlv2.ts:10407`（`checkPermission` no-op hook）
- **DB schema 已就绪**：snapshots / base variables / permissions / dashboards / sync configs 的表全部在 CE migrations（`src/meta/migrations/v0/`）里，多数功能只需补后端 service/controller + 解前端 stub

**改码约定**：所有本 fork 的修改处加行尾注释 `// [CE-EE]` 标记，便于对照上游合并。

### 2.1 F07 快照设计（fork 决策）

- 快照 = 用既有 DuplicateBase job 对 base 做**异步完整副本**（副本是普通 base，title 前缀 `Snapshot <ts> of`），登记在 `nc_snapshots`（status: processing→completed/error 按副本 base 派生）。**注意：副本是活的 base，非时点冻结**——对副本的后续修改会进入 restore 产物（fork 限制，EE 为冻结快照）
- restore = 对快照副本再复制为**新 base**「`<orig> (restored)`」，不原地覆盖工作 base
- 删快照 = `Base.softDelete` 副本（Base.delete 会触上游 "Cannot delete first source" 守卫，勿用）+ 删登记行；副本进 trash（平台统一语义）
- 加密：`NC_CONNECTION_ENCRYPT_KEY` 缺失时模型层静默明文——F05 service 层有守卫（拒 secret 物料写入）；F07 快照不复制 base variables（duplicateBase 无此 option），无 secret 物料通道。dev key 由 `.work/ee-ce/dev-backend.sh` 注入

## 3. 开发环境

- Node v26.3.0 / pnpm 10.34.5（仓库强制 pnpm，`preinstall: npx only-allow pnpm`）
- 安装：仓根 `pnpm install --frozen-lockfile`（或官方 `pnpm bootstrap` = 装 sdk → 构建 sdk → 装其余 → 构建 integrations）
- 后端 dev：`cd packages/nocodb` 后带 env 跑 rspack（端口 8080）：
  ```bash
  NODE_ENV=development NC_DISABLE_TELE=true ENTRYPOINT=src/run/docker \
    NC_DB='pg://<host>:5432?u=<user>&p=<pass>&d=nocodb-dev' \
    npx rspack --config rspack.dev.config.js
  ```
  注意：`pnpm watch:run:pg` 的入口 `src/run/dockerRunPG.ts` **硬编码** localhost NC_DB，勿直接用；外部 PG 必须自传 `NC_DB`（URL 格式 `pg://host:port?u=&p=&d=`）
- 前端 dev：`cd packages/nc-gui && pnpm dev`（Nuxt，端口 3000）
- 测试：后端 jest（`cd packages/nocodb && pnpm test`，testRegex `(Integration|Source|Fork)\.spec\.ts$`，CE 下仅 Fork 桶有文件；前端 vitest（`cd packages/nc-gui && npx vitest run --config test/vite.config.ts`）；无 Playwright

### 3.1 开发数据库（红线）

- **只用 `nocodb-dev` 库；`db=nocodb` 是生产库，严禁连接/读写！**
- 凭证源：Infisical → project `KDL`（`~/.zcode/.env` 的 `INFISICAL_PROJECT_ID_KDL`）→ secrets `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD`。⚠️ **该项目的 `DB_NAME` secret 值为 `nocodb`（生产库名）**——任何按 secret 流程拼连接串的脚本都会误中生产库！库名必须显式硬编码 `nocodb-dev`，绝不引用 `DB_NAME`（2026-09-14 R5 审查实测误连一次，零写入）
- **host 解析**：Infisical 里 `DB_HOST=pg18`（QNap 内部容器名），本机解析不了 → **用 `qnap.elf-balance.ts.net`**（Tailscale，5432 端口实测可达）
- 已验证：PG 18.2，`nocodb-dev` 库存在（首次启动 nocodb 自动建表）
- 凭证**禁止**写入任何被 git 跟踪的文件；脚本需凭证时运行时经 Infisical CLI 拉取（`.work/ee-ce/dev-backend.sh` 已封装）。红线指的是**真实凭证**（DB 密码/PAT/Infisical secret）；本地 dev 一次性测试账号的口令可写进 `.work` 下的测试脚本

### 3.2 构建与网络坑（实测记录）

- 安装顺序红线：`pnpm install` 的 nc-gui postinstall（`nuxt prepare`）要求 **nocodb-sdk 已构建**。新环境先 `cd packages/nocodb-sdk && pnpm build`（build = generate:sdk + tsc），再跑根 `pnpm install` 补 postinstall。
- sdk 的 `generate:sdk` 内部 `pnpm dlx swagger-typescript-api` 直连 registry 易超时 → 加 `npm_config_registry=https://registry.npmmirror.com`（整包下载同理；直连 registry.npmjs.org 元数据可能通但 tgz 下载间歇挂）。
- 后端 rspack 别名 `@noco-local-integrations` → `packages/noco-integrations/packages/`，但 CE 仓只有 `core/` → 需 `mkdir -p packages && ln -sfn ../core packages/core`（构建 `noco-integrations` workspace 之后）。
- dev server 起多个实例会互抢 dist/main.js（RunScriptWebpackPlugin autoRestart）→ 重启前先 `dev-backend.sh stop` 清干净。
- v2 records API 插入 body 为**平铺对象** `{"T":"x"}`；`{"fields":{...}}` 会被忽略字段静默写 NULL。
- 后端 dev 编译 ~20s；type-check ~2min 不阻塞启动；`/` 404 是正常（无前端 bundle），API 走 :8080。
- ts-jest legacy compiler 与 TS 5.8 有 document-registry 崩溃 → jest.config 已配 `isolatedModules: true`（transpile-only；类型检查走 `npx tsc --noEmit`，jest 不查型）。
- Infisical CLI `infisical login` 必须显式 `--domain "$INFISICAL_URL"`，缺参会 Invalid credentials。
- 上游遗留测试噪音（非 fork 引入，勿误判为 fork error）：nc-gui 全量 vitest 的 `pwa-self-destroying.test.ts`（import 已删的 pwa.config）必失败；`formula-url-xss` 并发抖动（单跑过）。跑定向测试文件即可避开（`packages/nc-gui/vitest.config.ts` 已建，裸跑 `npx vitest run <file>` 可用）。
- `NC_CONNECTION_ENCRYPT_KEY`：secret 型 base variables（及连接 config 加密）依赖此 env；缺失时模型层会**静默明文落库**。dev 由 `.work/ee-ce/dev-backend.sh` 注入 dev key；F05 service 层有守卫（缺 key 拒建 secret，400）。

## 4. 工作流（长程任务协议）

**机制一律从简引用全局 AGENTS**：多路复审 = §11（唯一入口 `/matrix --review`；阈值在 agents 仓 config.toml `[matrix.review]`），长程任务骨架 = §12（GOAL-STATE 七件套/巡检五态/修复验收铁律/实现批与阶段化）。恢复/续作唯一依据 = `.work/ee-ce/GOAL-STATE.md`（流程正本 TASK.md、全局进度 TODO.md 同目录）。

本节只记本项目差异：

- **F09 阶段划分**（每阶段独立 3 连击，交付即 pass）：P1 Table Sync manual 闭环 → P2 生命周期 → P3 realtime/incremental + AUTO → P4 LTAR 三层（范围与裁定见 f09-research.md 与各阶段 impl-report）
- **会审阵容实例**：5 路独立（外部 omp/pi/kilo/reasonix + subagent 补位，有效 ≥4；23:00–09:00 为 5 subagents；E3 缺席照全局 §11.8 补位）——报告归档 `.work/ee-ce/r<N>-p<M>-lane*.md`（P1-P3 历史命名 rN-fNN-*）
- **热修部署三步**：UNITEK 构建须带 `NODE_ENV/ENTRYPOINT`（缺则 Missing field entry；emit 后 rspack 可能挂死——grep 特征串确认 emit 完整即 kill）→ rsync dist 到 `~/.nocodb-run` → 受控重启 + **「进程启动晚于 dist mtime」双条件核验**
- 大功能循环（实现 → 自测 → 会审 → 收尾）的任务书/报告/归档落位与连线照全局执行；功能顺序调整需同步 TASK.md
- `.work/` 的 md/sh 白名单跟踪（见 .gitignore，2026-09-15 起进度态经 main 同步），重产物忽略；**凭证/密码永不入 `.work` 明文**

## 5. 禁止事项

- 严禁连接 `nocodb` 生产库（只许 `nocodb-dev`）
- 严禁把 `AZURE_DEVOPS_EXT_PAT` / DB 密码等凭证写进 git 跟踪文件或 commit
- 勿全局翻转 `isEeUI`；逐功能解 gate
- 勿引入官方 EE 仓专有代码（本就无权限；也不要从官方二进制/产物反编译）
- 杀进程前过全局 AGENTS §8（重启同种进程静默，杀无关进程需确认）
