# r3-f01-int-a — 集成测试（正向+边界）第 3 轮

对象：F01 Unique values only；dev server http://127.0.0.1:8080（nocodb-dev）；资源前缀 `f01r3a_`，测后 base 已删（baseSoftDelete，物理表随回收站保留，与 f01-e2e.sh 清理约定一致）。
方法：全 API 实测 + `uv run --with pg8000` 查 `nocodb-dev` PG（qnap.elf-balance.ts.net:5432，未触生产库）。

## 裁决：issues（1 error + 1 low；另有 2 项信息观察，非 error）

- `packages/nocodb/src/services/tables.service.ts:1122-1187`（tableCreate 列映射循环）: UUID 列在 NC-DB 建表路径未强制 unique，与 columnAdd 路径（columns.service.ts:4140-4207 强制 unique=true + readonly=true + storeUniqueConstraintNameInInternalMeta + 建唯一索引）不一致，违反 DR-2「UUID 必须唯一」的路径一致性: 建表循环内对 NC-DB source 的 UUID 应用与 columnAdd 相同的强制门（unique/readonly/约束名存储）。
  证据：`f01r3a_t11.u_uuid`（建表 payload 声明 uidt=UUID）meta `unique=null, readonly=false, cdf=gen_random_uuid()`，PG 无唯一索引；同表经 POST /api/v2/meta/tables/{id}/columns 加的 `u_uuid2` 为 `unique=true, readonly=true`，PG 有 `uk_<base>_<tid>_<cid>` 部分唯一索引。误差路径：仅建表路径。
- `packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:309-314`（633-639 同型）: 空字符串重复时错误体 `value="unknown"`（detail 提取 regex `Key\s*\([^)]*\)\s*=\s*\(([^)]+)\)` 不匹配空值，未回退 insertData）: 提取失败时回退 payload 原值（含 ''）或输出空串。低严重度：拦截与 fieldName 均正确，仅 value 语义失真（实测插第 2 个 `""` 返回 `value:"unknown"`）。

信息观察（非 error，不需本轮修）：

- `API GET pg_indexes` 两路径唯一索引形态不一：tableCreate=PG 原生 `<table>_<col>_key` 全表唯一索引；columnAdd=命名部分索引 `WHERE __nc_deleted IS NULL OR false`。实测 DELETE 记录为硬删（行从物理表消失），当前零行为差；若未来引入软删回收站，全表索引会阻止同值重插（部分索引不会）。建议后续统一形态。
- `POST /api/v2/meta/tables/{id}/columns` 与建表 schema 对 `unique:"false"/"yes"/"true"` 在 schema 层 400（报文为通用 oneOf 校验错，不点名 unique），PATCH 路径 schema 放行后由 service 报精确错「The unique flag must be a boolean value」。两者均 400+无状态变化，仅错误文案层级不一。

## 逐项结论（全实测）

| # | 项 | 结论 | 证据摘要 |
|---|---|---|---|
| 1 | 11 支持类型建表 unique:true | PASS（UUID 除外→见 error#1） | t11 建 12 列，SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time 全 `unique=true`；PG 11 条 `CREATE UNIQUE INDEX ..._key`。UUID 路径分歧见上 |
| 2 | 不支持类型 → 400 | PASS | columnAdd 12 类（LongText、LongText+richMode、Checkbox、MultiSelect、SingleSelect、Attachment、Rating、JSON、Duration、AutoNumber、Geometry、User）全 400「not supported for field type」，列零残留；tableCreate 建 LongText+richMode 表 400，表未建 |
| 3 | cdf 互斥 + UUID 例外 + 值判重 | PASS（value 提取瑕疵→low#2） | 建列 unique+cdf→400「Cannot enable unique constraint because a default value is set」；unique 列 PATCH cdf→400「Default values are not allowed for unique fields」；UUID 例外：u_uuid2 unique=true+cdf=gen_random_uuid() 共存。值判重：`hello`→dup 400；`Hello` 放行（DB 层大小写敏感）；`1`/`1.0` 数值等价 dup 400；NULL×3 放行；emoji dup 400；260 字符 OK+dup 400；空串 dup 400 |
| 4 | 改列路径 | PASS | 带重复开 unique→400「Found 2 duplicate values…」且索引未建（pg_indexes count=0）；清重→200，meta unique=true + `uk_...` 部分索引；关→200 unique=false + 索引消失（count=0）；重插同值→200；带重复再开再 400（回归） |
| 5 | 布尔归一回归 | PASS | columnAdd/tableCreate：`"false"/"yes"/1/"true"` 全 400 且无列/表残留；PATCH：`"false"/"yes"/1/"true"` 全 400「The unique flag must be a boolean value」且状态不变（unique=false 保持）；`unique:null`→200 无变化；true/false 正常开/关 |
| 6 | 错误映射 + bulk | PASS | 单插 dup→400 `{error:"FIELD_UNIQUE_CONSTRAINT_VIOLATION", fieldName:"u", value:"a"}`（fieldName 用 title）；bulk PATCH 批内两行同改同值→400 同错误 + 回滚（原值 c/e 不变）；bulk PATCH 撞已有值→400；bulk 插入批内重复→400 + 整批回滚（两行均未落库） |
| 7 | 并发 5 同值 | PASS | 共享单 token 5 并发插 `conc2`：恰 1×200 + 4×400 violation，PG 恰 1 行 |
| 8 | 改名保持 / 删列索引消失 | PASS | title 改名：meta unique 保持、索引保持、判重生效且 `fieldName`=新 title；物理列名改名 rn→rn2：索引跟随 `btree (rn2)`、判重保持；删列→索引消失（count=0） |

测试侧说明（非产品问题）：测试中段 3 次并发尝试遭同账号 signin 互踢污染（401），改共享 token 重测通过；首轮 5 并发结果作废以重测为准。
