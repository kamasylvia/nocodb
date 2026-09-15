# r8-f01-lane2 — F01 Unique 第 8 轮收敛确认（第 2 路：集成测试 + 代码复审）

- 轮次: R8（最终收敛确认）
- 审查对象: commit 744d31618b（F01 Unique values only）
- 隔离: 未读任何 r*.md 报告；仅读 TASK.md / 仓根 AGENTS.md / 源码 / dev server 实测
- dev server: http://127.0.0.1:8080 未重启未杀；测试账号 f06r8b 无效已回落 f01e2e@ce-ee.local
- 资源: base `f06r8b_base`（table `f06r8b_t1`，unique 列 `f06r8b_uniq`），测完已删

## 实跑门（rev 前置）

- `tsc --noEmit`（packages/nocodb）: exit 0，0 error — **过**
- `jest uniqueConstraintHelpers`: Tests 14/14 passed，Suites 1/1 — **过**

## int — 集成测试（全实测，v2 API，DB 为 nocodb-dev PG 18.2）

1. **bulk 批内重复 / 撞已存** — POST /api/v2/tables/{tid}/records 数组 body：
   - `[{b1},{b1}]` 批内重复 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（fieldName=f06r8b_uniq, value=b1），列表计数不变（整批 0 落库）
   - `[{c1},{a}]` 撞已存 'a' → 400 同码（value=a），'c1' 未落库
   - **过**
2. **更新撞值（两形态 PATCH）**：
   - 对象形态 PATCH /records `{Id,u:'a'}` 撞它行 → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION（value=a）
   - 数组形态 PATCH /records `[{Id,u:'a'}]` → 400 同码
   - 混合批 `[{b->b2},{c->a}]` → 400（value=a），b2 未落库（整批回滚）
   - 自值 b→b → 200；b→null → 200；两行同 null → 均 200（唯一索引带软删过滤，null 不冲突）
   - **过**
3. **并发 5 同值插** — Promise.all 5× POST `{f06r8b_uniq:'f06r8b_race'}`：
   - 恰 1 成（200）4 败（400），4 败全部 FIELD_UNIQUE_CONSTRAINT_VIOLATION，DB 恰 1 行
   - `?undo=true` 并发 5 → 同样恰 1 成；顺序 undo=true 重复插 → 400。undo 不绕约束
   - **过**
4. **列改名 / fieldName / DB 索引**：
   - PATCH title f06r8b_uniq→f06r8b_uniq_v2 后撞值（title 键与 column_name 键两种 payload）→ 400 且 fieldName=f06r8b_uniq_v2（跟随新 title），约束保持
   - pg8000 直查 nocodb-dev（host=qnap.elf-balance.ts.net，schema=pkvp29yvizv5hay）：改名后唯一索引在：`uk_pkvp29yvizv5hay_mukn907agrnyr32_ctggtfyck7tnvhw UNIQUE btree (f06r8b_uniq) WHERE __nc_deleted IS NULL OR false`
   - 删除新建 unique 列（f06r8b_uniq2 / f06r8b_x7）后：对应 uk_* 索引全部消失，无残留；主列索引保持
   - **过**
5. **非法输入矩阵 + 空串**：
   - unique:'false' / 'yes' / 'true' → 400（swagger ajv 层拦，列未创建；文案见 rev-O3）
   - unique:1 → 400 "The unique flag must be a boolean value"（service 层准确文案）
   - LongText / Attachment + unique:true → 400 "not supported for field type"
   - cdf:'dv' + unique:true → 400 "Cannot enable unique constraint because a default value is set"
   - 空串：''#1 → 200；''#2 → 400 且 `value:''` 从 payload 正确回显
   - **过**
6. **附加：解除/重开约束**：
   - unique true→false → 200，重复值可插；带 2 条重复值重开 → 400 "Found 2 duplicate values..."；清重后重开 → 200
   - **过**
7. **附加：PK 冲突可达性**：单条与 bulk 显式带已存 `Id:1` → 均被 API 剥离（200 新建自增行），PK 冲突无 v2 API 可达链

清理：base 删除 200，API 列表无残留；DB 唯一索引随删列消失已实证；DB 凭证临时文件已删。

## rev — 代码复审

范围：`helpers/uniqueConstraintErrorHandler.ts` 全文；`db/BaseModelSqlv2.ts` 三 catch（updateByPk:2900 / bulkUpdate:4642 / bulkUpdateAll:4821）+ `db/BaseModelSqlv2/insert.ts` 两 catch（single:234 / bulk:699）；周边 `exception-mapper.ts`（UniqueConstraintViolationError→400 FIELD_UNIQUE_CONSTRAINT_VIOLATION，v3 409）、`pg.extractor.ts`、`columns.service.ts`（normalizeUniqueConstraintFlag / validateUniqueConstraint / 重开重复检测）。

5 个 catch 接线模式一致：catch → trx rollback（bulk 类）→ handleUniqueConstraintError → error hook → throw。insert/bulkInsert/updateByPk/bulkUpdate/bulkUpdateAll 全路径覆盖，与 exception-mapper 串联闭合。columns.service 顺序正确：normalize（严格布尔）→ 启用校验（源类型/sqlite 拒绝/字段类型/cdf 互斥）→ 存量重复检测（duplicateDetectionService，实测生效）。

**issues：无 error 级发现。** 4 个观察项（均无 API 可达 error 链，行为正确或为死代码/文案问题，不构成必修）：

- O1 `uniqueConstraintErrorHandler.ts:699-701`：definitelyHas23505 分支 `else { column = uniqueColumns[0]; }` 会覆盖已从 errorDetail 正确解析的 column（多 unique 列时归因错列）。该分支仅当 errno 为字符串 '23505' 等第一段 has23505Anywhere 不覆盖的错误形态才可达，实测所有驱动形态（pg code、mysql errno/code、extractor 加工）均被第一段拦截，实际不可达。上游遗留冗余逻辑，建议后续清理对齐第一段。
- O2 `uniqueConstraintErrorHandler.ts:283-306`（及 628-641 重复块）：PG PK 冲突 pass-through（R2 fix）实际不可触发——errorDetail `Key (id)=(...)` 的 id 在 modelColumns 全列匹配命中 → `!column` 恒假 → pass-through 永不执行；uniqueColumns 为空时 254 行先 throw generic。但 v2 API 单条与 bulk 均剥离显式 Id（int-7 实测），PK 冲突无 API 可达链。注意：commit message 声称 "PK violations pass through (pg _pkey...)" 与代码实际行为不符（该声明路径未实现），建议修 commit 描述或补条件（对提取列做 unique/PK 属性判定而非存在性判定）。
- O3 列创建 unique 非布尔字符串（'false'/'yes'/'true'）被 swagger ajv 中间件先拦（400 行为正确、无绕过），但文案误导（报 `'uidt' must be one of: Formula...` 而非 unique flag 非布尔）；数字 1 到达 service 层报准确文案。根因在上游 swagger schema 无 unique 类型约束，属文案质量项。
- O4 `BaseModelSqlv2.ts:4645` / `insert.ts:703`：bulk 路径 insertData 仅取 `datas[0]`，多行批量且错误缺 detail/key 时归因回退可能取错列；PG/MySQL 驱动错误总含 detail/key 名，仅 extractor 加工后的错误受影响，错误类型与状态码不受影响。精度观察项。

## 裁决

- int: **PASS**（7 组场景全过，含对抗场景：并发、undo、软删过滤索引、约束解除/重开、PK 可达性探测）
- rev: **PASS**（实跑门 tsc 0 + jest 14/14；0 error，4 观察项 O1–O4 已列明）
- 总裁决: **PASS**
