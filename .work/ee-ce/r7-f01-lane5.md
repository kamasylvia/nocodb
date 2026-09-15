# r7-f01-lane5 — 第 7 轮 F01 会审（第 5 路独立：集成抽验 + 代码复审）

对象：commit `744d31618b`（F01 Unique values only）。账号 `f06r7b2@ce-ee.local`（专用）。资源前缀 `f06r7b2_`，已全部清理。隔离声明：未读任何 `r*.md` 报告，只读 TASK.md / 仓根 AGENTS.md / 源码 / 运行系统。

## int — 集成抽验（全实测，后端 :8080，PG nocodb-dev @ qnap.elf-balance.ts.net）

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 建列 unique:true → PG 索引在 | PASS | `f06r7b2_t1_Code_key :: CREATE UNIQUE INDEX ... USING btree ("Code")`（schema=base_id） |
| 2 | 重复插 → 400 | PASS | `POST /api/v2/tables/:tid/records` 同 Code 二插 → HTTP 400 |
| 3 | 关 unique → 重插成功 | PASS | `PATCH /api/v2/meta/columns/:cid {unique:false}` → 200；重插同值 → 200 Id=6 |
| 4 | editor 降权 → 403 | PASS | f06r7b2 降 base editor 后 `columnAdd` → HTTP 403 `ERR_FORBIDDEN ... action \"columnAdd\" ... roles: Editor` |
| 5 | 删列 → 索引消失 | PASS | `DELETE /api/v2/meta/columns/:cid` → 200；pg_indexes 仅剩 `_pkey/_order_idx/_deleted_idx` |
| 6 | 错误体无泄漏 | PASS | 错误体 keys = `{error, message, fieldName, value}`，无堆栈/SQL/路径/内部信息；空串重复插报 `value:""`（R3 fix 行为） |
| 附 | strict bool 校验 | PASS | columnAdd `unique:1` → 400 `The unique flag must be a boolean value`（service 层 normalize 拦截）；tableCreate `unique:"false"` → 400（HTTP Bool schema 拦截）；字符串值无法静默翻转约束 |

注：base editor 无 `tableCreate`（上游 ACL 语义，creator+ 专属），抽验 4 用 `columnAdd` 验证降权路径。

### 环境事件（非 F01 代码问题，如实记录）

测试中途后端 hang（:8080 不 accept 连接，rspack/main.js 进程存活但无响应）。按全局 AGENTS §8.2「重启同种进程」例外，经 `.work/ee-ce/dev-backend.sh` stop/start 静默恢复（~60s 起服），重启后完成剩余抽验全部通过。hang 根因证据被重启日志截断，无法归因；hang 前后的抽验序列各自完整通过，无 F01 相关错误。

## rev — 代码复审（commit 744d31618b 全 diff）

1. 安全审：PASS
   - 无凭证/密码/token 入 diff（13 文件全查）。
   - value 回显面：错误体 `value` 仅来自用户自身 payload（`insertData[col]` fallback）或 PG error detail 提取，无越权回显。
   - 注入路径：无。`constraintName`/`columnName` 仅字符串比较（`endsWith('_pkey'/'.PRIMARY')`）；MysqlClient 改动为删除无条件 `DROP INDEX` + 保留 `??` 参数化；normalize/validate 均为校验逻辑，无 SQL 拼接。
2. 一致性：见下方 issue 1；其余 PASS：
   - `[CE-EE]` 标记：diff 全部修改处均带（.gitignore / EditOrAdd.vue / useEeConfig.ts / jest.config.js / BaseModelSqlv2.ts / MysqlClient.ts / 两 helpers / 两 services）。
   - `isEeUI` 未动：`packages/nc-gui/utils/ncUtils.ts:1` 仍 `false`，commit 未触该文件。
   - AGENTS.md §3 测试描述与实测一致：`--listTests` 仅 2 个 Fork 桶文件（`uniqueConstraintHelpers.Fork.spec.ts` + `baseVariableValidators.Fork.spec.ts`（后者属 F05），Integration/Source 桶 CE 下无文件）。
3. 测试基建实跑：PASS
   - `npx tsc --noEmit` → 退出码 0，无输出。
   - `npx jest uniqueConstraintHelpers --runInBand --forceExit` → **14/14 passed**。
   - `npx jest --listTests` → Fork 桶 2 文件，与 AGENTS.md §3 描述一致。

## issues

1. `AGENTS.md`（仓根）: §2 「前端 paywall 中枢」行 — 文档与代码不一致（实测证实）：该行写各 feature gate「全部硬编码 blocked」，但 commit 744d31618b 同批已将 `blockUnique` 改为 `false`（`packages/nc-gui/composables/useEeConfig.ts:163`），commit 内即自相矛盾；当前工作树该行仍原样未更新，且工作树上 `blockBaseVariables:357=false`（F05）、`blockSnapshots:427=false`（F07）亦已解 gate，失真进一步扩大。任务书所述「§2 paywall 行已更新为『本 fork 已解 gate』表述」实测不存在。建议：该行改为「除本 fork 已解 gate（F01 unique；F05/F07 见 §1 表）外均硬编码 blocked」类表述，随下次 commit 同步。属文档准确性问题，不影响运行时行为。

## 总裁决

- int：PASS（6+1 项全过，含错误体无泄漏与 strict bool 双层拦截）
- rev：1 issue（AGENTS.md §2 paywall 行文档失真，单路属实、grep 实证；安全/标记/isEeUI/测试基建全 PASS）
- 本路结论：F01 代码面无 error；唯一 issue 为文档行，建议下一批 commit 顺手同步（不阻塞收敛判定，交 orchestrator 按 ≥2 路规则裁决）。
