# r2-f01-int-a.md — 第 2 轮会审 · 集成测试路（正向+边界）

- 对象：F01 Unique values only（R1 修复后全量复验）
- 环境：dev server http://127.0.0.1:8080（未重启未杀）；PG `nocodb-dev`（host `qnap.elf-balance.ts.net`，Infisical KDL `DB_*`，未触生产库）
- 资源：base `f01r2a_base`（puilbockbiycppb）+ 表 f01r2a_supported / f01r2a_uuid / f01r2a_strflag(未建成)，测完 DELETE /meta/bases/puilbockbiycppb → 200 true，已清理

## 结论

PASS

## 证据

### T1 支持类型建表 unique:true — PASS

POST /api/v2/meta/bases/puilbockbiycppb/tables，11 列（SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time）各 `unique:true` → HTTP 200，响应 11 列全部 `unique=true`（table id miakjjkuf0di7ut）。

PG 侧（pg8000 查 `pg_index`，schema `puilbockbiycppb`）：11 个 `indisunique=true` 索引全部落地，如
`CREATE UNIQUE INDEX "f01r2a_supported_Txt_key" ON puilbockbiycppb.f01r2a_supported USING btree ("Txt")`（Eml/Phn/Url/Num/Dec/Cur/Pct/Dt/Dtt/Tm 同构）。

### T2 不支持类型建表 unique:true → 400 — PASS

POST /api/v2/meta/bases/{baseId}/tables 各一列，全部 HTTP 400：

- Attachment → `Unique constraint is not supported for field type 'Attachment'`
- Checkbox → `...'Checkbox'`
- LongText → `...'LongText'`
- LongText(meta.richMode=true) → `...'LongText'`
- Lookup → `...'Lookup'`
- Rollup → `...'Rollup'`

### T3 cdf 互斥 + UUID 例外 — PASS

- 建表 unique:true + cdf → 400 `Cannot enable unique constraint because a default value is set. Please remove the default value first.`
- 加列（POST /api/v2/meta/tables/{tableId}/columns/）unique:true + cdf → 400 同上
- 反向：unique 列（Txt）PATCH 加 `{"cdf":"xx"}` → 400 `Default values are not allowed for unique fields. Please disable the unique constraint first.`；`{"cdf":"yy","unique":true}` 同样 400；GET 列确认 `cdf=None, unique=True` 状态未变
- UUID + unique + meta.autoGenerate → HTTP 200，列 `Uid unique=true`

### T4 值唯一性语义 — PASS

POST /api/v2/tables/miakjjkuf0di7ut/records（平铺 body）：

- `[{"Txt":null},{"Txt":null}]` → 200 `[{"Id":1},{"Id":2}]`（NULL 多行不冲突）
- `{"Txt":"dup1"}` 两次 → 第一次 200，第二次 400
- `{"Dec":1}` 200 后 `{"Dec":1.0}` → 400（数值等价）
- `{"Num":5}` 200 后 `{"Num":5.0}` → 400（整数列等价）

### T5 改列路径 — PASS

加列 Niu（默认非 unique）：

- 存在重复值时 PATCH `{"unique":true}` → 400 `Found 2 duplicate values in this field. Please edit or remove duplicates before enabling uniqueness.`（预检生效，未落索引）
- 清重后 PATCH `{"unique":true}` → 200，GET 列 `unique=true`
- PATCH `{"unique":false}` → 200，GET 列 `unique=false`；PG 查 `pg_index` 中 Niu 相关索引为空（索引已删除）
- 关闭后 POST 重复 `a,a` → 200 `[{"Id":15},{"Id":16}]`

### T6 非 boolean unique flag（R1 修复点）— PASS

PATCH /api/v2/meta/columns/{TxtId}，均 HTTP 400 且消息统一：

- `{"unique":"false"}` → `{"msg":"The unique flag must be a boolean value"}`
- `{"unique":"yes"}` → 同上
- `{"unique":1}` → 同上
- 三次 400 后 GET 列：`Txt unique=True cdf=None` — 约束状态不变，字符串 "false" 未误关

建表 columns 内 `{"unique":"true"}`（字符串）→ HTTP 400 `Validation failed: 'unique' must match exactly one of the allowed schemas`（schema 层 Bool 拦截，表未创建）。

### T7 唯一冲突错误体（R1 修复点）— PASS

两行 Txt=aaa/bbb 后 PATCH /api/v2/tables/{tableId}/records `[{"Id":10,"Txt":"aaa"}]` → HTTP 400：

```json
{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"Txt field unique constraint violation. Value 'aaa' already exists.","fieldName":"Txt","value":"aaa"}
```

`error` 字段 = `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（非 ERR_DATABASE_OP_FAILED），fieldName/value 正确。

## issues

无。
