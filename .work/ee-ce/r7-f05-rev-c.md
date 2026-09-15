# r7-f05-rev-c — 第 5 路（交叉面复审）R7 最终收敛报告

## issues

1. `/Volumes/UNITEK/Documents/Development/nocodb/.work/TODO.md`:F05 行(第 8 行):状态滞后一轮——仍写「R6 会审进行中（R5 全 PASS 连击 1/3）」,而 GOAL-STATE.md 已更新为「F05 R7 会审运行中（R6 全 PASS,连击 2/3）」;本轮任务验收点明列「TODO/GOAL-STATE 同步（R7 进行中）」,实测不同步。建议:将 TODO.md F05 行同步为 R7 进行中/连击 2/3 后再 commit。

## 实测证据（各项非 issue 项核验记录）

### 1. 安全终审:secret 全链路实测 — 全过
- DB 侧:uv + pg8000 连 `qnap.elf-balance.ts.net:5432/nocodb-dev`,`SELECT current_database()` = `nocodb-dev`(未触碰 `nocodb` 生产库);凭证运行时经 Infisical KDL `DB_*` 拉取,临时凭证文件置于 `.work/ee-ce/`(0600,`.gitignore:139` 已忽略),用后即删,测试账号(f05r7c/f05r7c2)已清理。
- 创建 secret 变量(API POST 200)→ DB `nc_base_variables.value` = `U2FsdGVkX1/0vtPPRc4Z…`(64 len,`value='r7c-plaintext-9137'` 判定 False)= **密文落库**。
- 轮换(PATCH 新 value 200)→ DB 换新密文 `U2FsdGVkX1/Am2zPzX87…`,新明文亦不在 DB。
- text→secret 翻转(PATCH 仅 type,无 value)→ 原明文 `plain-open-value` 被重加密为 `U2FsdGVkX1/D06oetYft…`。
- 单条 GET 解密回显明文正确;**三连读缓存稳定**(R2 双重解密修复无回归)。
- list 响应对 secret 行 value/default_value 完全剥除(JSON 中无该字段,掩码生效)。
- key 不入 git:`git status` 无 `.work` 项;全量 diff 无凭证字符串;`git check-ignore` 确认 `.work/` 被忽略。

### 2. 一致性 — 除上列 TODO 项外全过
- `[CE-EE]` 标记:diff 内 17 处标记;6 个新文件(service/controller/validators/Fork.spec/acl.test/vitest.config)均带文件级标记;Variables/index.vue 整文件新增,`<script setup>` 首行即标记。无漏标(AGENTS.md/lang json 为文档/不可注释格式,惯例不标)。
- `Api.ts`/nocodb-sdk:`git status packages/nocodb-sdk/` 为空 = 未动。
- `isEeUI`:`git diff packages/nc-gui/utils/ncUtils.ts` 0 行,仍 `false`;`src/ee` 目录不存在(stub 架构未变)。
- GOAL-STATE.md:已更新至 R7 运行中/连击 2/3 ✅;TODO.md 滞后(见 issue 1)。

### 3. 测试基建(全部实跑) — 全过
- 后端 `npx tsc --noEmit`:exit 0,0 错误。
- 后端 `npx jest`:2 suites passed,**26/26** tests passed。
- 前端 vitest(经新根 `vitest.config.ts`):fork 定向 `base-variables-acl.test.ts` **2/2 passed**;全量实跑 18 文件 = 16 passed / 130 tests passed + 5 skipped;仅 2 个 suite 失败且均为 AGENTS.md §3.2 已记录的上游遗留噪音(`pwa-self-destroying.test.ts` import 已删的 pwa.config 必失败;`formula-url-xss.test.ts` 并发抖动/超时 skip),非 fork 引入。

### 4. commit 前清单(对照 `git status --short`) — 全过
- 12 M + 6 ?? 共 18 项,逐项核对均属 F05 面:UI(index.vue/BaseSettingsMenu/View/useEeConfig)、ACL(lib/acl+utils/acl)、后端(Base.ts/BaseVariable.ts/noco.module.ts + 4 新文件)、i18n(en/zh-Hans)、AGENTS.md(R4 同步项:NC_CONNECTION_ENCRYPT_KEY 约定 + vitest 裸跑措辞)。无杂项、无 `.work` 泄漏、无临时文件残留。
- en.json 杂散空行 hunk 为 GOAL-STATE backlog 已挂账项(非本轮新增)。
