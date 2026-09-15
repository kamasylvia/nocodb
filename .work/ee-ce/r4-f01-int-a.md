# r4-f01-int-a — 集成测试(正向+边界)第 4 轮

环境:dev server 127.0.0.1:8080 + nocodb-dev(schema p7rhatbvo442k1u,测后已删 base + drop schema)。资源前缀 f01r4a_。

## issues 列表

1. `packages/nocodb/src/services/tables.service.ts:1149-1157`(R3 UUID 强制循环)+ `:1225`(`readonly: c.readonly || false`):**建表路径 UUID 只强制 unique=true、未强制 readonly=true**;加列路径两者都强制(`packages/nocodb/src/services/columns.service.ts:4152-4159` `colBody.readonly = true`)。实测:f01r4a_tuuid 建表带 `{title:'U',uidt:'UUID'}` → meta `unique=True, readonly=False`,随后显式插入 `{"U":"11111111-1111-1111-1111-111111111111"}` **被接受并落库**(Id=1),绕过 gen_random_uuid() 生成语义;对照 columnAdd 建的 UuidAdd 列 `readonly=True`,显式插入被拒(`Column "UuidAdd" is readonly column and cannot be updated`)。迁移注释 `src/meta/migrations/v0/nc_202604220000_uuid_readonly.ts:6` 声称新建 UUID 列均 readonly=true — 仅对加列路径成立,一次性 backfill 不覆盖之后新建的表。**建议**:tables.service 建表 UUID 循环内同步 `column.readonly = true`,镜像 columnAdd gate。

2. `packages/nocodb/src/services/tables.service.ts`(建表 DDL 路径)vs `packages/nocodb/src/services/columns.service.ts`(columnAdd/columnUpdate 启用路径):**同一 unique 开关,两路径产出的 PG 索引形态不一致**。建表路径 = 全量唯一索引(实测 `f01r4a_t11_Txt_key ... btree ("Txt")`,无 WHERE,11 列同);加列/启用路径 = 软删除感知的部分唯一索引(实测 `uk_p7rhatbvo442k1u_mih62c7ezjr7ebt_cybzgnoprpocgzg ... btree ("S") WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`)。影响:回收站行(trashed)对建表路径列永久占用唯一值,对启用路径列不占用;与 duplicate-detection.service 软删除过滤语义(排除 trashed)只在后者对齐。**建议**:统一索引形态(建表路径改用带 `__nc_deleted` 谓词的部分唯一索引,或反向统一),并补 internal_meta uk_ 命名一致性。

## 各项结论与证据

- **T1 11 支持类型建表 unique — PASS**。f01r4a_t11:SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time 逐列 `unique:true`;meta 全 unique=True;PG `f01r4a_t11_*_key` 11 条 UNIQUE INDEX 全存在(含 pkey/order/deleted 辅助索引正常)。
- **T2 不支持类型+richMode LongText — PASS**。建表路径 11 种不支持类型(LongText/LongText-richMode/Checkbox/MultiSelect/Attachment/JSON/Rating/Year/Duration/GeoData/Colour)全部 HTTP 400,msg 按 uidt 回显(`Unique constraint is not supported for field type 'LongText'` 等);columnAdd 路径 Checkbox/richMode LongText 同 400;失败请求无残留表。sqlite:只读核验 — `src/helpers/uniqueConstraintHelpers.ts:62-66` 显式拒绝(`'Unique constraint is not supported for SQLite databases'`),三处调用点均传 source.type(tables.service.ts:1166、columns.service.ts:1328、columns.service.ts:4035),建表/加列/改列三 DDL 路径全覆盖,不再静默丢 flag。
- **T3 UUID 建表路径回归 — FAIL**(见 issue 1)。meta.unique=true ✓、PG 唯一索引 `f01r4a_tuuid_U_key` ✓、readonly=true ✗ 且显式值可写入 ✗。
- **T4 cdf 互斥双向 + 值判重全项 — PASS**。互斥:①columnAdd cdf+unique 同带 → 400 `Cannot enable unique constraint because a default value is set`;②cdf 已存列 PATCH unique:true → 400 同;③unique 列 PATCH cdf → 400 `Default values are not allowed for unique fields`;④disable unique 后设 cdf → 200;⑤UUID 豁免:两路径 UUID 列 cdf=gen_random_uuid() 与 unique=true 共存。判重:1≡1.0(Decimal 1/1.0 启用被拒 count=1;启用后插 1.0 被拒 echo value='1')、emoji(🙂 重复拒/😎🚀 区分)、600 字符长文本重复拒、空串重复拒且**违规回显 value=''(非 unknown,R3 修复验证)**、NULL 多行可共存且启用后仍可插 NULL、大小写:PG 大小写敏感语义下 abc/ABC/aBc 共存(判重预检 GROUP BY 与 DB 索引行为一致),精确重复 abc 被拒 echo 'abc'。
- **T5 改列全链路 + 布尔归一 — PASS**。脏列启用 → 400 `Found 1 duplicate values...`(D/EM/LG/ES 四列验证,无索引残留);净列启用 → 200 + uk_ 索引出现;禁用 → 索引消失(pg uk_ 计数 6→5);再启用 → 6;布尔归一:`"false"/"yes"/1/0` 全部 400 `The unique flag must be a boolean value`,对已 unique 列发 `"false"` → 400 且 meta unique=True 保持、索引仍在(无静默翻转)。
- **T6 错误体 5 路径 — PASS**。单插/批量插(数组)/PATCH 对象/PATCH 数组/`PATCH /api/v1/db/data/bulk/noco/{baseId}/{tableId}/all?where=`(table id 形式)全部返回 `{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message","fieldName","value"}` HTTP 400;批量失败无部分落库(失败后行集不变)。注:v1 bulk 路由按 table **title** 解析失败(ERR_TABLE_NOT_FOUND)为通用行为 — 非 unique 的普通 bulk update 同样 404,与 F01 逻辑无关,未计 issue。
- **T7 并发/改名/删列 — PASS**。共享单 token 并发 5 同值单插 → 1×200 + 4×400,DB 恰 1 行(concurrentY);改列名(NU→NU2) → 200,meta unique=True 保持、PG 索引保持;删列 → 索引消失(uk_ 计数 6→5)。

## 结论

2 个 issue(1 必修:issue 1 UUID 建表 readonly 缺失 + 显式值可插入;1 一致性:issue 2 索引形态分叉)。未达全 PASS,需修复后开下一轮。
