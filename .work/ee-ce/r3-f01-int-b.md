# r3-f01-int-b.md — F01 Unique 第 3 轮 会审报告（独立第 2 路：集成测试-对抗面）

对象：`packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts`（R2 加固：移除自由文本 23505 扫描、PK/_pkey 直通）、`BaseModelSqlv2.ts`（updateByPk/bulkUpdate/bulkUpdateAll catch 接 handler）。
方法：全部 API 实测（dev server 127.0.0.1:8080，base f01r3b_base / 表 f01r3b_t1，双 unique 列 U1/U2 + Number N1 + LongText LT）+ pg8000 直查 nocodb-dev 物理索引。隔离遵守：未读任何 r*.md。

## 裁决：PASS（0 error）

---

## 分项结果

### 1. 加固回归 — PASS
- 1a unique 列插重复：`POST /api/v2/tables/{tid}/records {"U1":"v1",...}` → `400 FIELD_UNIQUE_CONSTRAINT_VIOLATION`，`fieldName=U1, value=v1`。
- 1b Number 列插含 23505 子串值 `{"N1":"abc23505xyz"}` → `400 ERR_DATABASE_OP_FAILED`，message=`Invalid value 'abc23505xyz' for type 'bigint'`，`details.dataType=bigint`。**非** FIELD_UNIQUE——自由文本 23505 扫描误判已消除（对照值 `"7"` 正常入库 200）。
- 1c/1d 显式 `{"Id":已存在}` / `{"Id":999001}` 插入 → 200，Id 均自动生成（5/6），显式 Id 被忽略（v2 records API 白名单行为），无 PK 撞库、无 5xx。记录不判。

### 2. PATCH 两形态 + 自值/null — PASS
- 对象形态撞 U2 → `400 FIELD_UNIQUE_CONSTRAINT_VIOLATION fieldName=U2 value=w2`。
- 数组形态撞 U1 → `400 ... fieldName=U1 value=v2`。
- 自值 PATCH（`{"Id":1,"U1":"v1"}`）→ 200 放行；null PATCH（`{"Id":1,"U2":null}`）→ 200 放行。

### 3. bulk 面 — PASS
正确路由为 3 段 `PATCH|POST /api/v1/db/data/bulk/noco/{baseId}/{tableId}`（`bulk-data-alias.controller.ts:27,50,68`）。
- 批内重复插入（两条同 U1）→ `400 FIELD_UNIQUE fieldName=U1`，整批回滚（DB 0 行残留）。
- 撞已存（新行+撞 v1 行）→ `400 ... value=v1`，整批回滚。
- `?undo=true` 撞值 → 仍 `400 FIELD_UNIQUE`，不绕约束；undo 正常路径 200。
- bulk PATCH 撞已存 → 400，目标行未变；bulk PATCH 批内互撞（两行设同 U1）→ 400，**两行均未变**（整批回滚）。
- bulk PATCH 自值 → 200。

### 4. 并发 — PASS
5 线程并发插同 U1 值 → `1×200 + 4×400 FIELD_UNIQUE_CONSTRAINT_VIOLATION`，无 5xx；pg8000 复核 DB 恰 1 行。

### 5. 列生命周期 + PG 索引核验（nocodb-dev，严禁生产库未违反）— PASS
- 建列 unique → 物理索引 `uk_{baseId}_{tableId}_{colId} ... USING btree ("U3") WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`（软删感知 partial unique index）；建表时列 U1/U2 为普通 `f01r3b_t1_U{1,2}_key` UNIQUE INDEX。
- 列改名 U3→U3R → 索引定义同步为 `ON ("U3R")`；改名后插重复 → `400 FIELD_UNIQUE fieldName=U3R`（归因用新 title）。
- `unique:false` → uk_ 索引消失，重复插入 200 放行。
- `unique:true` 且存量重复 → `400 {"msg":"Found 1 duplicate values in this field. Please edit or remove duplicates before enabling uniqueness."}`，索引不建（不静默半态）。
- 清重复后 `unique:true` → 索引重建（pg_indexes 复核在列），重复再被 400 拦截。
- 带索引删列 → 索引消失；off 态删列 → 无残留。函数路径 `single()`/`bulk()` catch 均接 handler（`BaseModelSqlv2/insert.ts:234,699`）。
- 期间 dev server 两次热重启窗口（`Restarting app...`，Connection refused ~1-2 分钟），恢复后 U1/U2 约束 sanity 仍生效。

### 6. bulkUpdateAll 面 — PASS
路由 `PATCH /api/v1/db/data/bulk/noco/{baseId}/{tableId}/all?where=...`（`bulk-data-alias.controller.ts:68`）。
- where 限定单行、set U1 撞已存 → `400 FIELD_UNIQUE fieldName=U1 value=v2`，目标行未被部分更新。
- where 无命中 → 200，count=0；自值更新 → 200 count=1；set null → 200。行为 = 400 unique 语义，判定合格。

### 7. 长文本/emoji/多 unique 归因 — PASS
- 10k 字符值（10003 字节）撞 U1 → `fieldName=U1`，`value` 完整提取 10003 字符（尾缀 `End` 正确）。
- emoji 值 `🚀😀🎉🙃` 撞 U2 → `value`/`fieldName` 精确；3000 emoji 前缀长值 distinct 插入正常。
- 双 unique 同时撞（payload U1 撞行 A 且 U2 撞行 B）→ 归因 PG 实际检出的约束（U1），value 对应。
- PATCH 组合负载（新长 emoji U1 + 撞已存的 U2）→ 归因 U2，未误报 U1。

---

## 观察（非 F01 违反，不计 error）
- `BaseModelSqlv2.ts:4821`（bulkUpdateAll catch）：`insertData: args?.data` 实际恒为 `undefined`（`data` 是第二形参，`args` 是查询参数对象），与 `bulkUpdate` catch 传 `datas[0]` 不对称。实测无行为影响（T6 归因靠 error.detail 提取路径，fieldName/value 均正确）；仅 detail 丢失场景会退化 `unknown`。建议后续改为透传 `data`。
- v1 单行插入路由（`data-alias.controller.ts:159` `POST /api/v1/db/data/:orgs/:baseName/:tableName`）收到数组 body 时静默插入全 null 行并返回 200（数组键访问全 miss）。属上游 v1 API 容错行为，F01 范围外，记录备查。

## 清理
- base `p317dvk99ue12q0` API 删除（200）；孤立物理表 `p317dvk99ue12q0.f01r3b_t1` 与 schema 已 DROP（pg8000 复核 0 残留）；临时凭证文件已删。
