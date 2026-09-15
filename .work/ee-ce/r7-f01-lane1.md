# R7 F01 — Lane 1 报告（int + rev）

对象 commit：`744d31618b`（F01 Unique values only）。三核心文件工作树与 commit 无漂移（`git diff 744d31618b -- <3 files>` 为空）；工作树其余改动属 F07，未混入。

## 实跑门（全部实测）

| 门 | 命令 | 结果 |
|---|---|---|
| tsc | `cd packages/nocodb && npx tsc --noEmit` | 0 错误（exit 0，无输出） |
| jest | `npx jest uniqueConstraintHelpers --runInBand --forceExit` | 14/14 pass |
| vitest | `cd packages/nc-gui && npx vitest run test/unique-constraint-helpers.test.ts` | 8/8 pass |

## int（dev server http://127.0.0.1:8080 实测；PG 直查 nocodb-dev @ qnap.elf-balance.ts.net，未触生产库）

账号：f01e2e@ce-ee.local（f06r7a 注册成功但为 org-level-viewer，无 baseCreate 权限，按预案回落）。资源前缀 `f06r7a_`。

### int1 — 12 支持类型 unique:true（11 常规 + UUID）
- 建表 `f06r7a_types`（SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time/UUID 各带 unique:true）→ 200。
- meta：12 列 `unique=true` 全部在位；UUID 列 readonly=true（tableCreate 强制门生效）。
- PG 索引（pg8000 直查 `pg_indexes`）：`f06r7a_types_u_{col}_key` UNIQUE btree 12 个全部在位。
- columnAdd 路径（`x_uuid2`）：partial unique index `uk_<base>_<tbl>_<colId> … WHERE __nc_deleted IS NULL OR false` 在位。
- 判定：PASS。

### int2 — 不支持类型 / richMode / cdf 互斥 / UUID 例外
- LongText unique → 400；LongText+meta.richMode → 400；Checkbox unique → 400；Attachment unique → 400。
- cdf 互斥双向：add(unique+cdf) → 400「Cannot enable unique constraint because a default value is set」；cdf 列 PATCH unique:true → 400；unique 列 PATCH cdf → 400「Default values are not allowed for unique fields」。
- UUID 例外：add UUID（auto cdf=gen_random_uuid()）→ 200 且 unique/readonly 强制 true；PATCH {unique:false,readonly:false} → 200 但 meta 复查仍 true（不可撤销）。
- 判定：PASS。

### int3 — 值判重
- NULL 多行：两行 v_text/v_dec 全 NULL 均插入成功（PG multiple-NULL 语义）。
- 数值等价：Decimal 1.5 → 200，1.50 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（value '1.5'）。
- 大小写：'Abc' → 200，'abc' → 200（PG btree 大小写敏感）；禁用→重启用 unique 对这两行 → 200（启用预检同样大小写敏感，两处语义一致）。
- 重复插：dup1 第二次 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（fieldName=v_text, value='dup1'）。
- 空串重复：'' 第二次 → 400，value=''（R3 修复生效）。
- 批量撞：bulkInsert [batch1,batch1] → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`，且按值查询 0 行（无部分落库）。
- 并发同 key：5 线程并发插 'race1' → 恰 1 成 4 拒（4×`FIELD_UNIQUE_CONSTRAINT_VIOLATION`）。
- 更新撞值：数组 PATCH（bulkUpdate→updateByPk）把已有行改成 'dup1' → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`；bulkUpdateAll（`/api/v1/db/data/bulk/noco/<baseId>/<tableId>/all?where=…`）全行改 'dup1' → 400 同错误码；同值 noop 更新 → 200。
- 判定：PASS。

### int4 — 严格布尔归一
- tableCreate：unique:"false" → 400（AJV schema 先拦）；unique:1 → 400（normalize helper「The unique flag must be a boolean value」）。
- columnAdd：unique:"false" → 400（AJV）；unique:1 → 400（normalize helper）。
- columnUpdate PATCH：unique:"false" / unique:1 → 400。
- UUID 列 PATCH unique:"false" → 200 但 meta unique 保持 true、readonly=true（R5 门先覆盖再归一，无字符串泄漏、无脏 meta）。
- tableCreate UUID 列 unique:false → 强制 unique=true、readonly=true。
- 判定：PASS。

## rev — 逻辑洞排查（helpers/uniqueConstraintHelpers.ts、columns.service.ts unique 分支、tables.service.ts UUID 门）

逐项检查，仅列有 API 可达链者；以下全部排除：

1. errorHandler `!column` 落穿分支（constraintName 非 `_pkey` 且存在 meta unique 列时怪罪 payload 列）：NC-DB PG 中唯一约束仅 meta 管理索引 + `<tbl>_pkey`，23505 detail 的物理列名必命中 meta 列 → 无可达链。
2. 大小写语义不一致疑点：运行时（DB 索引）与启用预检实测均大小写敏感、行为一致；`normalizeValueForUniqueCheck`（lower/trim）仅用于 duplicate-detection.service.ts:223 的 UI 重复定位，不进闸门 → 无洞。
3. 列转 UUID 绕门疑点：含重复值列 PATCH uidt→UUID → 400「Found 1 duplicate values…」meta 不变；空列转 UUID → 400「Cannot convert 'x_conv1' to UUID. UUID values are auto-generated — create a new UUID column instead.」→ 不变量不可绕过。
4. columnUpdate UUID 门对未带 unique 键的 PATCH 注入 unique:true → colBody 与既有状态相同（no-op），无 DDL/meta 漂移。
5. 观察项（非 error，上游 CE 既有，fork 未触碰 DDL 生成器）：tableCreate 路径建 full unique index、columnAdd 路径建 partial unique index（过滤 `__nc_deleted`），软删行判重行为两路径不同。

系统事件：测试中途 8080 瞬断一次（rspack 重建 ~80s 自恢复）导致首轮部分 401，已重跑修复；非 F01 代码问题。

## 清理
- base `pklt3637r6sy0rm`（f06r7a_base）经 API 删除 → meta 404；物理 schema 随 trash 生命周期保留（产品语义）。测试表/列/行全部随 base 消亡。f06r7a 专用账号保留（任务指定创建）。

## 裁决

**PASS**（int PASS + rev 无 error；0 issue）
