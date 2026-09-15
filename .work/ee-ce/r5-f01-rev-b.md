# r5-f01-rev-b — 第 5 轮会审,第 4 路(后端深水区复审)

复审对象:handler 全文(`packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts`,1092 行)、三入口归一(columnAdd / columnUpdate / tableCreate)、update 三路径 catch(updateByPk / bulkUpdate / bulkUpdateAll)、R4 五项修复终核、GOAL-STATE R3/R4 backlog 复核。
方法:攻击性读码 + 源码级可达链追踪,未读他路报告。

## 裁决:issues(1 error)

### E1 (error): UUID 强制门可被 columnUpdate 一击撤销 — R4/R1 修复不闭环

- 文件:`packages/nocodb/src/services/columns.service.ts`
- 位置:columnUpdate 归一段(~1311-1350)与 colBody 组装(~1370)+ updateMetaAndDatabase 落库段(~712-726 `Column.update(context, column.id, {...column})`)
- 问题:R1 给 columnAdd 加了 UUID 强制门(`colBody.unique = isNcDbSource ? true : ...`,~4152;`colBody.readonly = true`,~4162),R4 给 tableCreate 加了镜像(tables.service ~1147-1160)。但 **columnUpdate 路径没有任何镜像/守卫**:
  1. `readonly` 键:columnUpdate 全程不 strip 也不覆盖该键(仓内 `deleteColumnSystemPropsFromRequest` 不删 readonly,且只被 columnAdd/tableCreate 调用,columnUpdate 未调用);`Column.update2` 的 extractProps 白名单**含 'readonly'**(`packages/nocodb/src/models/Column.ts` ~1554)→ 请求体 `readonly:false` 直落 meta,解除 R4 建的 readonly 标志。
  2. `unique` 键:归一段 `if (!param.column.unique && column.unique) { // Disabling is allowed }`(~1322-1325)无 UUID 特判 → UUID 列 unique:false 直接走 tableUpdate drop 约束路径,绕过 "UUID fields must have unique constraint (per PRD requirement DR-2)" 语义。
- API 可达链(全链读码实锤,与 int-a R4 实测的"显式 UUID 值可落库"同一洞的残余路径):
  1. `POST /api/v2/meta/tables/{tableId}/columns` body `{uidt:'UUID', ...}`(pg NC-DB 源)→ 列落 readonly=true / unique=true(columnAdd 强制门);
  2. `PATCH /api/v2/meta/tables/{tableId}/columns/{colId}` body `{"readonly": false}` → meta readonly 解除(colBody 原样进 `{...colBody, id: column.id}` → updateMetaAndDatabase → Column.update 白名单落库,无 400);
  3. `POST /api/v2/tables/{tableId}/records` body `{"<uuid列title>": "固定值"}` → BaseModelSqlv2 insert readonly 守卫(~4243 `!allowSystemColumn && col.readonly`)因 meta 已 false 而放行 → 显式值落库,gen_random_uuid 不再生成;
  4. (可选)`PATCH .../columns/{colId}` body `{"unique": false}` → 约束 drop → 重复值自由落库,23505 永不再触发。
  即:E1 单独第 2-3 步即可复现 int-a R4 实锤的同一个数据层绕过;第 4 步进一步撤掉 DB 兜底约束。
- 建议:在 columnUpdate 归一段(~1311)对 `column.uidt === UITypes.UUID && (source.is_meta || source.is_local)` 镜像 columnAdd 门:强制 `colBody.unique = true`、`colBody.readonly = true`(或在 updateMetaAndDatabase 前对 UUID 列统一强制),使 update 时点与 add/create 时点不可分叉。

## R4 修复终核(5/5 在位)

1. sqlite 双值判定('sqlite'/'sqlite3')✅ — `uniqueConstraintHelpers.ts:63-68`;`DriverClient.SQLITE='sqlite3'`(`src/utils/nc-config/constants.ts:84`)证实 'sqlite3' 为实际值,'sqlite' 为无害防御。
2. UUID 建表 readonly 镜像 ✅ — `tables.service.ts:1155-1158` 设 `column.readonly=true`,经 Model.insert `readonly: c.readonly || false` 落 meta;insert/update 守卫(BaseModelSqlv2 ~4243/~6159)配合生效。**但该修复可被 E1 链撤销,见上**。
3. bulkUpdateAll `insertData: data` ✅ — `BaseModelSqlv2.ts:4821`;`data` 为调用方第二参数(alias 原始 payload),handler 以 `column_name ?? title` 双键查,两种形态均可命中;与 updateData(mapAliasToColumn 后)不冲突。
4. mysql PRIMARY 直通 ✅ — handler:771-776,位置在 extractColumnNameFromError 之后、payload 猜测之前,语义正确。残余:MySQL 8 的 key 名带 `db.tbl.` 前缀时直通失配(见 backlog B1)。
5. 空串回退 `??` ✅ — handler:318-324 / 653-659,`payloadValue !== undefined && !== null` 后 `String('')=''`,detail 可提取时空串重复正确显示空串;detail 丢失场景仍退化为 'unknown'(见 backlog B3)。

## 三入口归一 / update 三路径 catch 复核

- 布尔归一:三入口均先 `normalizeUniqueConstraintFlag` 再分支;`undefined`(未请求)三态处理正确;tableCreate 的 UUID 门设在 normalize 之前(unique=true 为 boolean,归一幂等)✅。
- DDL 侧确认:PG(`PgClient.ts:3201-3204` change=0 内联 `UNIQUE`)与 MySQL(`MysqlClient.ts:2699-2702` change=0)建表 DDL 均读 `n.unique`,UUID 门对两库 DDL 均生效;R1 的 mysql `addUniqueConstraintToQuery` 无条件 DROP INDEX 移除(`MysqlClient.ts:2657-2668`)在位,change=1/2 添加路径只 ADD CONSTRAINT ✅。
- update 三路径 catch:updateByPk(2897-2904)、bulkUpdate(4640-4647,先 rollback 后 handler,重复行查询不受事务回滚影响)、bulkUpdateAll(4820-4826);insert single/bulk(`BaseModelSqlv2/insert.ts:236-243 / 698-706`)亦接 ✅。共 5 接线点,无遗漏的写路径。

## backlog 复核(GOAL-STATE R3/R4 节)

原 backlog 各项复核结论 + 本轮新增:

- A. 表创建内联 UNIQUE vs partial 分叉:**维持,范围需补充**。读码实证两处分叉:① trash 维度(原 backlog 已记):partial(`PgClient.ts:3604`,`WHERE (col IS NULL OR col=false)`)不索引软删行,inline 索引全部行;② **NULL 维度(原记录未含)**:partial 把 NULL 行纳入索引(两个 NULL 冲突),PG inline UNIQUE 依语义允许多 NULL——trash 关闭态下两路径对 NULL 行为也不等价,原"trash 关闭态等价"表述不完整。**UUID 建表强制门不扩大该分叉影响面**:UUID 列值由 gen_random_uuid() 生成,恒非 NULL、恒唯一,NULL/trash 两个分叉维度对 UUID 列均不可达;门只是把"建表必带 UNIQUE 约束"应用到 UUID,行为等价。
- B1 (新): MySQL 8 duplicate key 消息的 key 名带 `db.tbl.` 前缀 → handler:101 `for key ['"]?([^'"]+)['"]?` 捕获整串,`columnName === 'PRIMARY'` 直通(R4 修复)失配;external mysql 源(uniqueColumns=0)时 PK 冲突落入 handler:907 throw `UniqueConstraintViolationError{unknown,unknown}` 而非透传原错误(与 R2 #2 修复意图相悖的同类残余)。多 unique 列时正常 unique 归因也可能错列(payload 猜测兜底取首列)。无 MySQL 测试库,读码推定,附完整链供实测。
- B2 (新): partial index 的 NULL 语义(见 A ②)——后加 unique 列上第二个 NULL 插入会触发 23505/FIELD_UNIQUE,与建表 unique 列行为不一致;属 A 的细化,不单独修。
- B3 (新): R3 空串回退只覆盖 detail 可提取场景;detail 被 extractor 处理丢失时,payload 猜测段(handler:329-351 / 664-698 / 962-968)的 `!== ''` 过滤与 `||` 链使空串重复显示 'unknown'。文案级。
- C. 原有各项维持:isUniqueViolation.ts 死代码(全仓无引用,grep 证实);handler 第二段(definitelyHas23505,:583-739)为第一段的死代码复写(输入域被 has23505Anywhere 覆盖,读码证实);bulk datas[0] 猜列局限;v1 数组 body 静默插 null;外部 pg 组合 unique 报错文案 split 限制(手工 DDL 组合约束误归因首列,同型);pwa-self-destroying.test.ts 上游自带失败。均不修,记录。

## 实跑验证

- `npx jest --silent`:**14/14 passed**(uniqueConstraintHelpers.Fork.spec.ts 含 R4 sqlite 回归守卫)。
- `npx tsc --noEmit`:**exit 0,0 error**。
