# r7-f01-lane4 — 第 7 轮收敛确认（DDL/跨库侧重，int + rev）

裁决：**PASS**

- 账号：f06r7a2@ce-ee.local signup 后 roles=No Access 无法 baseCreate → 按任务书回落 f01e2e@ce-ee.local；资源前缀 `f06r7a2_`，已全部清理（base pm5drygo91nfsku + schema drop + meta 行 + 物理表 0 残留；凭证临时文件已删）。
- 被测：commit 744d31618b，dev server :8080（未重启），PG nocodb-dev @ qnap.elf-balance.ts.net:5432。

## rev（代码复审）

- 实跑门：`tsc --noEmit` exit 0；`jest uniqueConstraintHelpers` 14/14 PASS（isolatedModules 桶）。
- PgClient.ts（上游 CE 代码，blame 确认非 fork 改动；fork 依赖其链路）：
  - tableUpdate 预查询段（:2588-2640）：oIsUnique→nIsUnique 关闭时 internal_meta 缺名则 queryUniqueConstraintName 回填 oldColumn.internal_meta — 实测该回退路径生效（见 int-2 C2/C3）。
  - drop 分支（:3405-3428）：DROP CONSTRAINT IF EXISTS + DROP INDEX IF EXISTS（schema 限定）双保险，同时覆盖 constraint 形态（建表内联）与 partial index 形态（加列）。
  - queryUniqueConstraintName（:3441-3479）：contype='u' + conkey[1]=attnum 过滤正确；catch 返回 null 安全降级（随后走生成名 + IF EXISTS，不炸）。
- MysqlClient.ts R1 fix（:2657-2661 DROP INDEX 移除）：两调用点核验成立——change===1 为新列（索引不可能存在）；change===2 仅 nIsUnique && !oIsUnique 才进 add（旧列非 unique → 无索引）。无条件 DROP INDEX 确实必 1091，移除正确。drop 分支（:2738-2744）保留 DROP INDEX，名字由 internal_meta/tableUpdate 预查询（:2111-2158）保证。
- models/Base.ts 双挂钩幂等（F07 未提交改动一并看冲突）：softDelete（F07 R2 fix 段）+ delete 两处均调 `BaseSnapshot.cleanupByBaseIdWithCopies`；幂等成立（注册行删后 list 空 → no-op；copy base 已删时 catch 吞掉、行清理仍执行）；dynamic import 防循环依赖；递归有界（copy base 注册行为空）。F01 未改 Base.ts，与 F07 改动零交集，无冲突。
- 前端 gate 现状：useEeConfig `blockUnique = computed(() => false)`；EditOrAdd.vue:1512 gate 于 `!blockUnique` — 与 commit 一致。

## int（PG 实测，全部通过）

1. **建表路径 vs 加列路径索引形态**：
   - 建表（t1.title）：`f06r7a2_t1_create_title_key` = full UNIQUE CONSTRAINT（pg_constraint contype='u' + 自动 btree 索引，无 WHERE）。
   - 加列（t2.code）：`uk_<base>_<model>_<col>` = partial unique index（`WHERE __nc_deleted IS NULL OR false`），无 pg_constraint 行。
   - trash 关闭态行为等价：删除为硬删（`__nc_deleted` 无 tombstone，remaining=0），删后重插同值两表均 200；重复插入两表均 400 同构错误体。等价成立 → PASS。
2. **constraint 名管理 开→关→开**：
   - 关：索引 + 约束全部消失（pg_indexes/pg_constraint 双查），关闭态 dup 插入 200。
   - 开（加列路径）：重建 partial index，`nc_columns_v2.internal_meta.unique_constraint_name` == 实际索引名，逐字符一致。
   - 开（建表路径列）：重建为 partial index 形态（columnUpdate 统一走 addUniqueConstraintToQuery，softDelete 列存在），internal_meta 同步存名且生效（dup 再被挡）。初次建表 full 与 edit 后 partial 的形态差异系上游 CE 设计，trash 关闭态语义等价，非 fork 引入。
   - dup pre-check：关闭态存在重复值时重开被 400 拒（"Found 1 duplicate values..."），防护正确。
3. **布尔归一/校验矩阵/错误体（15 项抽查）**：
   - colUpdate `unique="false"/"yes"/1/0/"true"` → 400 `The unique flag must be a boolean value`；缺省/None → 200。
   - tableCreate `unique="false"` → 400（schema 校验）、`unique=1` → 400。
   - UUID 列 tableCreate 传 `unique:false,readonly:false` → 落库强制 unique=True readonly=True。
   - 错误体：insert / bulkInsert / record update / bulkUpdate 重复 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION` + fieldName + value；空字符串重复 → `value:""`。
   - 例外说明（非系统问题）：显式重复 Id 插入返回 200 新行 — v2 API 忽略 body 中 Id（自增分配），PK 冲突无法经该 API 触发；PK passthrough 逻辑由 jest spec 覆盖。

## 观察项（不判 error，无需本轮修复）

- PgClient.ts:3453 queryUniqueConstraintName 的 pg_attribute join 未过滤 `attisdropped`——需 dropped 列与目标同名校验才可能误配，极边缘。
- BaseSnapshot.ts:182 cleanupByBaseIdWithCopies 对 copy base softDelete 失败 silent catch——可能残留活 copy base（F07 范围，注释已声明取舍，注册行清理不受影响）。
