# r6-f01-lane5 — 第 6 轮 / F01 / 第 5 路（int + rev 交叉）

日期：2026-09-12。commit：744d31618b。隔离声明：未读 .work/ee-ce/ 下任何 r*.md；只读 TASK.md、AGENTS.md、源码、运行系统。全项独立重跑。

## int（集成抽验，全实测）

后端 http://127.0.0.1:8080（勿重启遵守——测试中后端一度失联 21:57–22:06，系 rspack watch 重编译周期，自行恢复，本路未动进程）。
账号：f06r5a@ce-ee.local 登录成功（org-level-creator）；建 base 需 workspace 级角色，经回落账号 f01e2e 完成（共享账号 JWT 会被并行 sign-in 顶掉，全程改用 base 级 API token 隔离）。资源前缀 f06r5a_。

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 建列 unique:true → PG 索引在 | PASS | meta 返 `unique=True`（列 id cn5hghhlzpuner1）；pg8000 查 nocodb-dev（qnap.elf-balance.ts.net，schema p4qx23vkksz0j5l）：`CREATE UNIQUE INDEX uk_p4qx23vkksz0j5l_m2fklf4m0sejzye_cn5hghhlzpuner1 ON p4qx23vkksz0j5l.f06r5a_t1 USING btree (f06r5a_uniq) WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))` |
| 2 | 重复插 400 | PASS | POST /api/v2/tables/m2fklf4m0sejzye/records 同值二插 → HTTP 400 |
| 3 | 关 unique 重插成功 | PASS | PATCH 列 unique:false → 200；同值重插 → 200（Id:3）。反向 toggle 亦验：删重复行后 unique:true 重开成功、索引重建无命名冲突（间接证明 disable 已真删索引） |
| 4 | editor 降权 403 | PASS | f06r5a 以 editor 邀入 base 后：columnAdd → 403 `Forbidden ... "columnAdd" with the roles: Editor`；columnUpdate(unique:false) → 403。数据面不越权误伤：editor 插记录放行、插重复值 → 400 结构化错误（行为合理） |
| 5 | 删列索引消失 | PASS | DELETE 列 → pg_indexes 仅剩 pkey/order_idx/deleted_idx，uk_* 消失；information_schema 确认物理列 f06r5a_uniq 已删 |

错误体核验：PASS。重复插 400 body：
`{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"f06r5a_uniq field unique constraint violation. Value 'dupval1' already exists.","fieldName":"f06r5a_uniq","value":"dupval1"}`
— 无堆栈、无 constraint 名、无 SQL/PG 内部信息、无表名/库名泄漏。creator 与 editor 两身份实测一致。

清理：API token id4 删除（base 删除前路径拒绝 API token 自删，base 软删后随 trash 失效）；f06r5a_base 已删（软删 → trash，active list 不再出现）；editor membership 随 base 删除失效；临时凭证/响应文件已删。
残留（非阻塞）：① f06r5a@ce-ee.local 账号行留在 nc_users（与既有持久测试账号同模式）；② trash 中有本轮软删 base；③ 发现**前轮遗留**资源未清：active list 存在 `f06r5a_base`（id=pwx09ca7syqyfps，非本轮创建）及 PG 遗留 schema pm9u82yffzix8js——非本路资源未动，提请 orchestrator 处置。

## rev（代码复审，commit 744d31618b 全 diff）

1. 安全审：PASS。
   - 凭证：13 文件无任何凭证/密码/token（AGENTS.md 仅提及 Infisical secret 键名与路径，无值）。
   - value 回显面：错误回显限 fieldName + value 两字段；value 来源 = PG 错误 detail 正则捕获或用户本次 payload 回落（R3）。同表冲突值回显不超出该表读者已有可见面；JSON 字段传输，无 HTML/XSS 注入向量。
   - 注入路径：无。MysqlClient `addUniqueConstraintToQuery` 全部经 `genQuery('??', ...)` 参数化（DROP INDEX 分支同）；errorHandler 对 DB 错误文本只做正则提取后进 JSON 错误消息，不落 SQL/eval；normalizeUniqueConstraintFlag 强制 boolean 后才入 meta，无原始字符串透传。
2. 一致性：PASS。
   - [CE-EE] 标记：F01 全部代码修改点均有标记（EditOrAdd.vue / useEeConfig / jest.config / BaseModelSqlv2 ×3 / MysqlClient / errorHandler R2+R3+R5 / helpers R1+R3 / columns.service R1+R5 / tables.service R1+R3+R4）；测试文件与 .gitignore 亦带。
   - isEeUI：commit 未触及 ncUtils.ts，现值仍 `false`。
   - AGENTS.md §2 paywall 行（今日更新版）核准确：代码实测 `blockUnique=false`（163 行）/ `blockBaseVariables=false`（357）/ `blockSnapshots=false`（427，工作树 F07 变更，与未提交 AGENTS 同批）；`blockSync`/`blockPrivateBases`/`blockDocumentPermissions`/`blockAddNewDashboard` 仍 true——「已解 gate」清单与「硬编码 blocked」清单均与代码一致。§1 状态表 F01=代码完成、F05=pass 与 git log 一致。§3.1/§3.2 描述与实测一致（nocodb-dev、host 解析、isolatedModules）。
3. 测试基建实跑：PASS（含 1 项披露）。
   - `npx tsc --noEmit` → exit 0，无输出。
   - `npx jest uniqueConstraintHelpers --runInBand --forceExit` → 14/14 passed，1 suite。
   - `npx jest --listTests` → **2 文件**，非任务书预期的「恰 1」：第 2 个 `baseVariableValidators.Fork.spec.ts` 属 F05 commit 6ab23da0（已核实其 commit 文件清单）。Fork 桶机制本身正确（只匹配 fork 自有 spec）；「恰 1」预期写于 F05 落地前，系任务书措辞滞后，**非 F01 缺陷**，按观察项披露供裁决，不计 error。

## 裁决

- int：PASS（5/5 + 错误体）
- rev：PASS（安全 / 一致性 / 基建）
- **总裁决：PASS（0 error）**；非缺陷观察项 2 条（listTests=2 系 F05 落地致任务书措辞滞后；前轮 f06r5a 遗留资源待 orchestrator 清理）。
