# r5-f01-int-b — F01 第 5 轮 集成测试·对抗面（第 2 路独立复审）

环境:dev server :8080 / PG `qnap.elf-balance.ts.net:5432` db=`nocodb-dev`（pg8000 只读核验，未触生产库）。
资源:`f01r5b_base`/`f01r5b_tbl`（UniqueCol+UniqueCol2 均 unique）/`f01r5b_tbl2`，测完已删（API 层 base 软删 200，物理表按上游软删保留于 dev 库）。
测试脚本:`.work/ee-ce/r5b_t1.sh`~`r5b_t6.sh`、`r5b_pgq*.py`。

## 结论:PASS（0 实际违反；2 项范围外观察见末节，不计 F01 error）

## 1. 加固回归 — PASS

- 1a 重复插 FIELD_UNIQUE:`POST /records {"UniqueCol":"dup1"}` 两次 → 第 2 次 `400 {"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","fieldName":"UniqueCol","value":"dup1"}`。
- 1b "abc23505xyz" 非 FIELD_UNIQUE 误判:插入非 unique `NormalCol="abc23505xyz"` → `200` 正常落库；含 23505 的值 `only23505a` 重复插入 → 正确归因 `UniqueCol`/`only23505a`，无 message 数字误判（R2 结构化 code 检查生效）。
- 1c 多 unique 列归因精确:撞 `UniqueCol`（UniqueCol2 新值）→ `fieldName=UniqueCol,value=dup1`；撞 `UniqueCol2`（UniqueCol 新值）→ `fieldName=UniqueCol2,value=fresh2a`。归因逐列精确。
- 1d 空串:首次 `UniqueCol=''` → `200`；第二次 → `400 FIELD_UNIQUE value=''`（R3 空 value 回退 payload 生效，非 'unknown'）。
- 1e 显式 Id 自动生成:`{"Id":9999,"UniqueCol":...}` ×2 → 分别得 `Id=9`、`Id=10`，9999 被剥离（`prepareNocoData` insert 非 undo 删 ai pk），无 PK 撞。

## 2. bulk 三场景回滚 + undo 撞值 + 并发 — PASS

- 2a bulk 3 行全新值 → `200 [{Id:12},{Id:13},{Id:14}]`，count 6→9。
- 2b 批内 [新,撞 dup1,新] → `400 FIELD_UNIQUE dup1`，回滚实证:`bulk_b1`/`bulk_b3` 查 0 行，count 仍 9。
- 2c 批内自身重复 [x,x,y] → `400 FIELD_UNIQUE bulk_c1`，`bulk_c9` 查 0 行（整批回滚）。
- 2d undo 撞值拦截:删 Id=10(`explicitid2`) → 新行占用该值（Id=19 成） → `POST /records?undo=true {"Id":10,...}` → `400 FIELD_UNIQUE explicitid2`，`Id=10` 查 0 行（无部分重建）。
- 2d-control undo 无撞值:删 Id=30 → `?undo=true` 同 Id 重放 → `200 {"Id":30}`，行重建（undo=true 保留显式 Id 语义正确）。
- 2e 并发 5 同值 race_v1:1×`200 {Id:20}`，4×`400 FIELD_UNIQUE race_v1`，DB `race_v1` 恰 1 行。PG 约束仲裁正确。

## 3. bulkUpdateAll — PASS

- 撞值:`PATCH /api/v1/db/data/bulk/noco/{baseId}/{tableId}/all?where=(UniqueCol,in,bulk_a1,bulk_a2)` set `UniqueCol=dup1` → `400 FIELD_UNIQUE dup1`；3 行原值不变（bulk_a1/a2/a3 保持）。
- 自值:where 单行 set 原值 → `200` count=1，无假违反。
- null:where 3 行 set `UniqueCol=null` → `200` count=3（PG 多 NULL 允许），3 行 UniqueCol 全 null。
- 行完整性:其余列（Id1/3/6/7/19/20 的 NormalCol/UniqueCol2 等）全保持原值。
- 备注:v1 bulk 路由按 table id 可用；按 title 别名 404 — 见范围外观察 O1。

## 4. 列生命周期 PG 索引核验 — PASS

- 建表带 unique → PG `pg_constraint`:`f01r5b_tbl_UniqueCol_key UNIQUE ("UniqueCol")`、`f01r5b_tbl_UniqueCol2_key`（全量约束）。
- `PATCH unique=false` → 原 `_key` 约束/索引消失（pg_indexes 实证）。
- `PATCH unique=true` → 重建为部分唯一索引 `uk_p11r0acc87z1js1_mv107vl3aoaez51_czg0xwu5saflmya ... WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`，且 `internal_meta.unique_constraint_name` 与索引名逐字一致。
- 有重复时 enable 拒绝:disable → 插 2 条同值（均 200）→ enable → `400 "Found 1 duplicate values..."`（count=盈余行语义，duplicate-detection.service `total-distinct`，实测自洽），行未动；删 1 条后 enable → `200`。
- cdf 与 unique 互斥:unique 列设 `cdf` → `400 "Default values are not allowed for unique fields..."`。
- 非布尔 flag:`"unique":"false"` → `400 "The unique flag must be a boolean value"`（R1 生效）。
- Number 列 unique 支持:UvNum 建 unique=true 成功（meta true），删列后其唯一索引消失（终态 pg_indexes 无 UvNum 索引）。
- 一致性观察 O2（非 error）:建表路径=全量约束 `_key`；重建路径=软删感知部分索引 `uk_`。本 fork `Model.isTrashEnabled=false`（CE），两者行为等价；语义分歧属潜在项，无功能违反。

## 5. meta↔DB 一致性抽样 3 处 — PASS

- 抽样 1:`f01r5b_tbl.UniqueCol` nc_columns_v2 `unique=true` ↔ PG `f01r5b_tbl_UniqueCol_key UNIQUE ("UniqueCol")` ✓
- 抽样 2:`f01r5b_tbl2.UniqueCol` `unique=true` + `internal_meta.unique_constraint_name="uk_p11r0acc87z1js1_mv107vl3aoaez51_czg0xwu5saflmya"` ↔ pg_indexes 同名索引逐字一致 ✓
- 抽样 3:`f01r5b_tbl.NormalCol` `unique=null` ↔ NormalCol 零索引；UvNum 列删后 meta 与索引均消失 ✓

## 6. 混合 payload + typecast 插入路径 — PASS（行为记录）

- `{"Id":777,"UniqueCol":"mix1","Other":null}` → `200 Id=25`:显式 Id 剥离；未知键 `Other` 静默忽略；`mix1` 正常落库。
- `{"fields":{"UniqueCol":"wrap1"}}` → `200 Id=26`:fields 包裹形态整体忽略 → 全 NULL 行（上游已知行为，AGENTS.md §3.2 在案，非 F01 引入）。
- `?typecast=true` 数值 `12345` 入 text unique 列 → `200` 存为 `"12345"`；再以字符串 `"12345"` 插入 → `400 FIELD_UNIQUE value='12345'`（typecast 路径 unique 约束不失效）。
- 默认无 typecast 数值 `67890` → `200` 存 `"67890"`（记录性:无 typecast 也接受数值入 text）。

## 范围外观察（非 F01 error，供 orchestrator 分诊）

- O1 v1 数据 API title 别名解析失效:`/api/v1/db/data/bulk|data/noco/{baseId}/{title}` 对本测表与上游自带表（GettingStarted/Features）均 `ERR_TABLE_NOT_FOUND`，按 table id 可用（`Model.getByAliasOrId` title 分支）。F01 diff 未触该函数（Model.ts 近 8 提交 0 CE-EE 标记），上游建表同现 → 既有/上游范围，非本轮引入。
- O2 见 §4:unique 生命周期两种 DDL 形态（全量约束 vs 软删感知部分索引）并存；CE trash 关闭下行为等价。
- 附注:失败插入消耗 PG 序列（Id 跳号 2/4/5/8）= PG sequence 正常语义，非缺陷。
