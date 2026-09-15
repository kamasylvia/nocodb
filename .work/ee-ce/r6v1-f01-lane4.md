# r6-f01-lane4 报告（第 4 路：集成测试 + 代码复审，DDL/跨库/spec 侧重）

账号 f06r4a@ce-ee.local（新建成功但默认 org-level-viewer 无 baseCreate 权限）→ 按预案回落 f01e2e@ce-ee.local（super+org-level-creator）；资源前缀仍 `f06r4a_`，测完已删（API DELETE base 200 + `DROP SCHEMA ppslkvuuqs7iky5 CASCADE`，`pg_tables LIKE 'f06r4a%'` 已空）。

## int（PG 实测，全数通过）

1. **两路径索引形态核验**（pg8000 直查 pg_indexes/pg_constraint，host qnap.elf-balance.ts.net，仅 nocodb-dev）：
   - 建表路径 T1：内联全量 constraint `f06r4a_t1_uqcol_key`（contype='u'，btree unique index 无 WHERE）。
   - 加列路径 T2：partial unique index `uk_ppslkvuuqs7iky5_mjxa62a0o2p5vpl_cih3ogl6jriszte` `WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`。
   - trash 关闭态行为等价：两表插入重复值均 400，无行为分歧。PASS。
2. **constraint 名管理**：
   - T2 加列路径：OFF → constraints=[] 且 unique_indexes=[]（0 残留）；ON → 新索引重建，名确定性（`uk_<base_id>_<fk_model_id>_<col_id>` ID 模式），`nc_columns_v2.internal_meta = {"unique_constraint_name":"uk_..."}` 与物理索引名逐字一致。
   - T1 建表路径：internal_meta 为空时 drop 前经 queryUniqueConstraintName 查 pg_constraint 命中 PG 自动名 `f06r4a_t1_uqcol_key`，干净删除（降级查询路径实测有效）；ON → 重建为 partial index + internal_meta 一致。
   - 开关后重复值仍被 400 拒绝；空串重复同理。
3. **布尔归一/校验矩阵/错误体抽查（10 项）**：
   - columnAdd unique:"false" → 400；unique:"yes" → 400；unique:1 → 400 `The unique flag must be a boolean value`
   - columnUpdate unique:0 → 400（同消息）；unique:"true" → 400
   - tableCreate 列 unique:"true" → 400（`'unique' must match exactly one of the allowed schemas`）
   - 合法值 columnAdd unique:false → 200；columnUpdate unique:false/true → 200/200
   - 错误体：`{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"uqcol field unique constraint violation. Value 'dup' already exists.","fieldName":"uqcol","value":"dup"}`；空串重复 `value:""`
   - UUID 列 tableCreate：unique+readonly 均强制开启
4. 说明：PK violation 穿透无法经 API 实测（单行 PATCH /records/:rowId 路由不存在，返回 404 Cannot PATCH），该项由 jest uniqueConstraintErrorHandler 套件覆盖（14/14 含 PK passthrough 用例）。

## rev（代码审读 + 实跑门）

1. **PgClient.tableUpdate unique 增删段**（src/db/sql-client/lib/pg/PgClient.ts:2596-2645、3383-3431）：drop 分支链路 internal_meta → queryUniqueConstraintName 补名 → getUniqueConstraintName(o) 取名；随机后缀 fallback 仅在「internal_meta 缺 + ID 缺 + DB 查不到」三重缺失时触达，NC 列对象恒带 base_id/fk_model_id/id → ID 模式确定性命中，未发现可达的残留场景。DROP INDEX 带 schema 限定（`t.includes('.')` → `schema.index`），修非默认 schema 下 unqualified drop 静默 miss。partial index（非 constraint）时 pg_constraint 查不到 → ID 模式名兜底命中（建时同名），实测 T2 OFF 干净删除证实。
2. **queryUniqueConstraintName**（PgClient.ts:3441-3485）：schema 限定 `nspname = schema || this.schema`，表名取末段去 schema 前缀，attnum/conkey 匹配单列，catch → null 降级。MysqlClient 同构（:2537，INFORMATION_SCHEMA.STATISTICS NON_UNIQUE=0，可命中 MySQL 建表内联 UNIQUE 的自动名），MysqlClient.tableUpdate:2139 drop 前同样补名 —— 跨库建表→关 unique 链路均闭环。
3. **MysqlClient R1 后两调用点语义**（:2717 change===1 ADD COLUMN；:2736 change===2 且 nIsUnique!==oIsUnique 且 nIsUnique）：均仅在旧列非 unique（索引不可能存在）时触达 addUniqueConstraintToQuery，移除无条件 DROP INDEX 后不再误触 1091；drop 分支 `, DROP INDEX ??` 使用补过的真实名。
4. **Base.ts 双挂钩**（softDelete 区 :456 附近 / delete 区 :706 附近）：均 `await BaseVariable.deleteByBaseId + BaseSnapshot.deleteByBaseId`；两实现为 metaDelete 条件删 + NocoCache.deepDel，重复/双路调用幂等（删 0 行 + 缓存 no-op）。F05/F07 同文件改动相邻排列，import 与挂钩无冲突。
5. **实跑门**：`npx tsc --noEmit` exit 0；`npx jest uniqueConstraintHelpers` 14/14 passed。

## 裁决

- int：PASS
- rev：PASS
- 总裁决：**PASS**
