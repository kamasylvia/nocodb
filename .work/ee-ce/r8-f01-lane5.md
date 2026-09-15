# r8-f01-lane5（第 5 路独立：int 抽验 + rev 交叉复审）

对象：commit 744d31618b4ac4b90e526791fa1d213c9b870977（F01 Unique values only）
环境：dev backend http://127.0.0.1:8080（未重启）；PG = nocodb-dev @ qnap.elf-balance.ts.net:5432（未触生产库 nocodb）
账号：f06r8b2@ce-ee.local（本轮 signup 新建，专用于本路，避免多路 signin token_version 互踢）；creator 面操作用回落账号 f01e2e@ce-ee.local
资源：base f06r8b2_base（p3xdqy1pv208pye）→ 测完 DELETE 200（trash 语义，schema 残留属上游统一行为）；临时凭证文件已 rm

## int（抽验，全实测）

1. 建列 unique:true → PG 索引在 — PASS
   - POST columnAdd `{unique:true}` 200；meta `unique:true`，`internal_meta.unique_constraint_name = uk_p3xdqy1pv208pye_m6cc430jupac6nl_crp3da5xlrdjfd7`
   - pg_indexes 实查：`CREATE UNIQUE INDEX uk_..._crp3da5xlrdjfd7 ON p3xdqy1pv208pye.f06r8b2_t1 USING btree (f06r8b2_code) WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`（partial unique，软删豁免设计）
2. 重复插 400 — PASS
   - 同值第 2 插 HTTP 400：`{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"f06r8b2_code field unique constraint violation. Value 'dupval' already exists.","fieldName":"f06r8b2_code","value":"dupval"}`
   - 错误体仅 error/message/fieldName/value 四键：无堆栈、无 SQL、无 pg 驱动内部信息（int#2 ✓）；value 回显 = 用户自己提交的 payload 值，无泄漏面
3. 关 unique 重插成功 — PASS
   - v1 PATCH `/api/v1/db/meta/columns/{id}` `{unique:false}` 200 → `pg_indexes` uk_ 索引消失 → 同值重插 HTTP 200（Id=4）
   - 附加验证：带重复值时 PATCH unique:true → 400 `Found 2 duplicate values in this field...`（duplicate pre-check 正确拒绝）
4. editor 降权 403 — PASS
   - f06r8b2 邀请为 base editor 后：PATCH column → 403 `ERR_FORBIDDEN ... "columnUpdate" ... roles: Editor`；columnAdd → 403 `"columnAdd"`。错误体干净
5. 删列索引消失 — PASS
   - 列在带 uk_ 索引状态下 DELETE column 200 → pg_indexes 该列 uk_ 索引消失，仅剩 pkey/order_idx/deleted_idx
   - 注：DDL 为异步，断言需 sleep 2-3s（实测一次 3s 内索引未及建成的假阴性，复查确认索引已建，非缺陷）

## rev（交叉面）

1. commit 744d31618b 全 diff 安全审 — PASS
   - 无凭证：13 文件无任何密码/PAT/连接串；`.gitignore` 仅新增 `.work/` 与 integrations shim
   - value 回显面：errorHandler 的 value 仅来自 PG error detail 提取或用户 payload 回填，均属用户自有值，回显到自家响应无越权信息
   - 无注入路径：`normalizeUniqueConstraintFlag` 强制 boolean（"false"/1 拒 400）；constraint name 为服务端生成 `uk_<schema>_<table>_<colId>`，用户输入不进 DDL 拼接；free-text `'23505'` 扫描已移除（structured 检测），误判面收窄
2. 一致性 — PASS
   - [CE-EE] 标记：全部 fork 修改处带 `// [CE-EE]`（R1-R5 轮次标注齐全：useEeConfig / EditOrAdd / columns.service / tables.service / BaseModelSqlv2 / MysqlClient / uniqueConstraintHelpers / errorHandler / jest.config / .gitignore）
   - isEeUI：commit 树与工作树均 `packages/nc-gui/utils/ncUtils.ts:1 = false`，未动；git diff 744d31618b 对该文件为空
   - AGENTS.md：工作树 §1 F01 =「代码完成(commit 744d3161)，会审收敛中」；§2 paywall 行含「**本 fork 已解 gate**：`blockUnique`（F01）/ `blockBaseVariables`（F05）/ `blockSnapshots`（F07）= false」，与 useEeConfig 代码（blockUnique=false）一致；§3 测试段 testRegex 描述与 jest.config.js 实配一致
3. 测试基建实跑 — PASS
   - `npx tsc --noEmit` → exit 0
   - `npx jest uniqueConstraintHelpers --runInBand --forceExit` → 14/14 passed（validateUniqueConstraint 9 + normalizeUniqueConstraintFlag 2 + normalizeValueForUniqueCheck 3）
   - `npx jest --listTests` → Fork 桶 2 文件：uniqueConstraintHelpers.Fork.spec.ts（F01）、baseVariableValidators.Fork.spec.ts（F05）；Integration/Source 桶 CE 下无文件，与 AGENTS.md §3 描述一致

## 观察项（非 error，不判违反）

- 多路并行共用 f01e2e 账号触发 signin token_version 互踢（本路多次 401 根因）——环境流程问题，非被测代码缺陷；建议各路 signup 专属账号
- `bulkUpdate` 多行冲突时 errorHandler `insertData: datas?.[0]` 取首行 payload 回填 value，多行场景 value 提示可能对不上冲突行（fieldName 恒正确，best-effort 提示字段，无安全影响）
- v2 records DELETE 个别记录返 404（记录实际存在，PG 可见）——非 F01 面通用 API 行为，未深究，仅记录
- MysqlClient DROP INDEX 移除仅代码审读（dev 环境无 MySQL 可实测）；add 方向 1091 修复逻辑自洽，remove 方向属上游既有路径

## 裁决

int：PASS（5/5 抽验 + 错误体 + pre-check 附加全过）
rev：PASS（安全审 / 一致性 / 测试基建三项全过）
总裁决：**PASS**（0 error）
