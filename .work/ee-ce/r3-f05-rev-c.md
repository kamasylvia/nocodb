# r3-f05-rev-c.md — F05-R3 交叉面复审(第 5 路 rev-c,2026-09-12)

审查范围:`git status --short` + 全量 diff + 4 个未跟踪新文件 + 安全实测(nocodb-dev)+ tsc/jest 实跑。
隔离:未读任何 r*.md;只读 TASK.md / 仓根 AGENTS.md / GOAL-STATE.md / .work/TODO.md / 源码 / f05-e2e.sh。

## 实测记录(证据)

- 安全全链路(nocodb-dev,凭证 Infisical KDL DB_*,host qnap.elf-balance.ts.net,未触生产库):
  - 创建 secret `SECRET_R3C` → API 200;list 响应中 value/default_value 字段整体不存在(掩码)✅;单条 get 返回解密明文(creator token)✅
  - pg8000 直查 `nc_base_variables`:`value = 'U2FsdGVkX1+gyeVIrdnnZHpct/o2mIcKk/6P9DEQyUI='`,≠明文,CryptoJS AES 密文形态 ✅
  - 非 creator(Editor 角色)单条 get → 403 `Forbidden ... "baseVariableList" with the roles: Editor` ✅
  - 删 base → `nc_bases_v2.deleted=true`(soft delete 链路)→ 变量行 0 残留(deleteByBaseId 挂 softDelete 实测生效)✅
- 加密 key:dev key 值 `git grep` 0 命中;`dev-backend.sh` 在 `.work/`(gitignore:139,git ls-files .work = 0);backend.log 中 key 值/测试 secret 明文 0 泄漏 ✅
- tsc:`npx tsc --noEmit` exit 0 ✅;jest:2 suites 26/26(unique 14 + baseVariableValidators 12,spec 实数 12 it)✅
- backend.log:无 F05 相关 error(仅上游 401 auth 噪音与 route map 日志)✅
- Api.ts / isEeUI(ncUtils.ts)未动 ✅(git status 无)
- spec 位置:services/ 下无 Fork.spec;`helpers/baseVariableValidators.Fork.spec.ts` 在位 ✅
- [CE-EE] 覆盖:全部功能改动行有标记(lang JSON 文件无法携带行注释,合理豁免);R2 补的 View.vue/BaseSettingsMenu.vue 标记在位 ✅
- commit 清单:12 M + 4 ?? 与任务清单一致,无多余无缺失;AGENTS.md(§3.2 一行)为文档同步伴生件应一并提交;jest.config 未改 ✅
- AGENTS.md §3.2 `NC_CONNECTION_ENCRYPT_KEY` 约定已入(diff 1 行)✅

## issues

- (low) `.work/TODO.md:8` — F05 条目仍写「R1 会审进行中」,GOAL-STATE.md:5-11 已是「F05-R3 会审 5 路运行中」:两状态源不一致,违反任务项 4 的同步要求:建议改 TODO.md F05 行为 R3 进行中。
- (low) `packages/nocodb/src/services/base-variables.service.ts:151-153` — `ensureEncryptionAvailable` 的 `isSecretWrite = (value !== undefined && type === undefined)` 分支覆盖**任意 type 的行**,与注释「only enforce when a secret value is actually being written … value write on a secret row」不符:缺 key 部署下对 TEXT 变量 PATCH `{value}`(不带 type)被误拒 400。当前 dev 带 key 且 UI PATCH 恒带 type,实际不可达;方向保守无安全影响:建议改为按 `existing.type`(或 `type ?? existing.type`)判定。
- (low) `.work/ee-ce/GOAL-STATE.md:17` — R2 记录称 deleteByBaseId「移挂 Base.softDelete」,实际 `Base.ts` 在 `delete`(~:695,R1 钩子)与 `softDelete`(~:447,R2 钩子)两处均挂:双保险更稳、无行为问题,但「移挂」与 diff「两处并存」描述不符:建议 GOAL-STATE 措辞改为「delete 补挂 softDelete(双链路)」。

无 error 级问题。
