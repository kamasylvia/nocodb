# r6-f01-lane4 — F01 第 6 轮会审(第 4 路: DDL/跨库侧 集成测试 + 代码复审)

## 裁决: PASS

(int = PASS; rev = PASS; rev 实跑门 = PASS。无 error 级 issue。)

---

## rev 实跑门(先决)

- `npx tsc --noEmit`(packages/nocodb): exit 0,无输出。
- `npx jest uniqueConstraintHelpers`: **14/14 passed**(1 suite,66.6s)。

---

## int — 全实测(nocodb-dev, PG 18.2, qnap.elf-balance.ts.net:5432, 库=nocodb-dev; 未触生产库)

环境: 账号 f06r4b@ce-ee.local 无创建权(org-level-viewer)→按预案回落 f01e2e@ce-ee.local(super+creator); 资源前缀 `f06r4b_`,base=pc3z9jjrr3yb41z(schema 同名),表 A=`f06r4b_t_create`(建表路径内联 unique 列),表 B=`f06r4b_t_addcol`(纯建表后 columnAdd 加 unique 列)。

### int-1 建表路径 vs 加列路径 unique 索引形态(pg8000 直查 pg_indexes/pg_constraint)

- A(建表路径): `f06r4b_t_create_ucol_key` = **全量 UNIQUE constraint**(pg_constraint contype='u',UNIQUE (ucol),无 WHERE 谓词)——对应 PgClient alterTableColumn change===0 内联 `UNIQUE`。
- B(加列路径): `uk_pc3z9jjrr3yb41z_m9zqtzfe91vz8tr_cqdslwnumm1euu7` = **partial unique index**(`WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`)——对应 tableUpdate→addUniqueConstraintToQuery(检测到 __nc_deleted 系统列走 partial 分支)。
- 形态差异与已知结论一致(建表内联全量 vs 加列 partial)。
- **行为等价(trash 关闭态)验证**:
  - 重复插入: A 第 2 次 400 / B 第 2 次 400,错误体逐字段一致(`{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","message":"ucol field unique constraint violation. Value 'dup-*' already exists.","fieldName":"ucol","value":"dup-*"}`)。
  - NULL 多次插入: A/A/B/B 全 200(PG 全量 constraint 与 partial index 均允许多 NULL)。
  - 空字符串重复: 第 2 次 400,`value":""` 取自 payload ✓(uniqueConstraintErrorHandler 语义)。
  - 本实例 trash 关闭态: DELETE /api/v2/tables/:id/records 为硬删(物理行消失),两路径无差异。
  - **等价 → 该项 PASS**。

### int-2 constraint 名管理(开→关→开 ×2 轮,PATCH /api/v2/meta/columns/:colId)

- OFF: A(inline constraint,无 internal_meta)与 B(partial index,有 internal_meta)均 200;直查确认 A 的 unique constraint 与 B 的 uk 索引**全部消失**(pg_indexes/pg_constraint 双查为空)——A 走 tableUpdate 预查 pg_constraint 回填名(`f06r4b_t_create_ucol_key`)后成功 DROP,B 走 internal_meta 存名成功 DROP INDEX。
- ON: 两列均 200,重建为 partial unique index(表含 __nc_deleted):
  - B: 索引名**往返稳定** `uk_..._m9zqtzfe91vz8tr_cqdslwnumm1euu7`(与原 internal_meta 名逐字符一致);
  - A: 新名 `uk_<base_id>_<model_id>_<col_id>`(= uk_pc3z9jjrr3yb41z_m68wsgdft34567j_c7z4tq0sk0krlk0,62 字符 < 63 上限)。
- internal_meta 一致性: `nc_columns_v2` 两列 `internal_meta.unique_constraint_name` 与 pg_indexes 实际索引名**逐字符一致**(两轮 OFF→ON 后均复验一致)。
- ON 后重复插入仍 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION。
- **PASS**。

### int-3 布尔归一/校验矩阵/错误体(11 项)

| # | 场景 | 期望 | 实测 |
|---|---|---|---|
| T1 | ON 后 insert 重复 | 400 structured | ✓ FIELD_UNIQUE_CONSTRAINT_VIOLATION(fieldName+value) |
| T2 | updateByPk 造重复 | 400 同上映射 | ✓ 同上(updateByPk 路径) |
| T3 | bulkUpdate 造重复 | 400 同上映射 | ✓ 同上(bulk 路径) |
| T4 | tableCreate unique:"true" | 400 | ✓ schema 校验拒(unique 仅允许 boolean/缺省) |
| T5 | columnAdd unique:"false" | 400 | ✓ schema 校验拒 |
| T6 | columnUpdate unique:1 | 400 | ✓ "The unique flag must be a boolean value"(normalizeUniqueConstraintFlag) |
| T7 | columnUpdate unique:"yes" | 400 | ✓ 同 T6 |
| T8 | LongText + unique | 400 | ✓ "not supported for field type 'LongText'" |
| T9 | cdf + unique | 400 | ✓ "a default value is set..." |
| T10 | 重复值列上开 unique(dup pre-check) | 400 | ✓ "Found 1 duplicate values in this field..." |
| T11 | 空串重复错误体 value='' | 400 | ✓(见 int-1) |

- 说明: columnAdd/tableCreate 的非布尔 unique 由 JSON-schema 层先拒,columnUpdate(PATCH 无 schema)由 normalizer 拒——两道防线均 400,commit 声称的 ""false"/"yes"/1 → 400" 三入口成立。
- 未测: PK 冲突透传(23505 on PK)——v2 API 无可行触发路径(Id 为 AI 只读),由 jest spec 覆盖(14/14 内含 passthrough 用例)。
- **PASS**。

### trash 开态 divergence(观测,非 error)

DB 直改 __nc_deleted=true 模拟软删行后重插同值: B(partial)**放行 200**,A(全量)**拒绝 400**。即建表路径列在 trash 开态下软删行会阻塞同值——与"建表内联全量 vs 加列 partial"已知差异同源;验收口径为 trash 关闭态等价(已证),且开关一次 unique 即转为 partial(见 int-2),故不计 error。

---

## rev — 代码复审

### db/sql-client/lib/pg/PgClient.ts(tableUpdate unique 段 + queryUniqueConstraintName 及配套)

- tableUpdate 预查块: 仅在 (altered&2|&8) 且 oIsUnique&&!nIsUnique 且 internal_meta 缺名时回填,JSON.parse 容错 ✓。
- drop 分支: `DROP CONSTRAINT IF EXISTS` + schema 限定 `DROP INDEX IF EXISTS` 兼容 constraint/partial index 两种形态,IF EXISTS 保证幂等 ✓(int-2 实证两形态均真删)。
- addUniqueConstraintToQuery: 先 DROP 旧名(约束+索引)再建;partial 谓词 `IS NULL OR = false` 与加列路径一致;pk/ai 列保持全量 constraint ✓。
- queryUniqueConstraintName: pg_constraint contype='u' 单列限定 + schema 限定,异常返 null 不炸 ✓。
- 名长: id 化名 62 字符,随机 fallback 截 63,满足 PG 63 上限 ✓(int-2 实测 62)。
- genQuery `??` 绑定 `schema.index` 复合标识符由 knex 按点拆分转义 ✓。

### db/sql-client/lib/mysql/MysqlClient.ts(DROP INDEX 移除后调用点)

- addUniqueConstraintToQuery([CE-EE] R1 fix)已无无条件 `DROP INDEX`;仅 `, ADD CONSTRAINT ?? UNIQUE (??)`。
- 全部调用点核验(3 处): change===1(新列,索引必不存在)、change===2 add 分支(nIsUnique&&!oIsUnique,旧索引必不存在)、tableUpdate 预查块——**无误触 1091 的调用点** ✓。
- drop 分支保留 `DROP INDEX ??`(MySQL 语义必需),依赖 internal_meta/tableUpdate 预查(information_schema NON_UNIQUE=0)提供真名,与 PG 侧同构 ✓。MysqlClient 无 IF EXISTS 语法,依赖名正确性,可接受(名由本仓管理并持久化)。

### models/Base.ts 双挂钩幂等(+ F07 同文件改动冲突检查)

- delete()(硬删)与 softDelete()(软删)均挂钩 `BaseSnapshot.cleanupByBaseIdWithCopies`,hook 位置在 BaseVariable 清理之后、meta 删改之前,顺序合理。
- 幂等: cleanup = list(snapshot rows)→逐行 softDelete 副本(catch{}容错,副本已删不阻断)→deleteByBaseId(删登记行)。二次调用 list=[] → no-op;softDelete→delete 序列安全 ✓。
- 递归有界: 副本 base 的 nc_base_snapshots 登记为空(duplicateBase 不复制快照登记),cleanup 内 softDelete 副本触发副本自身 hook 即空转 ✓。
- F01/F07 冲突: F01 commit(744d3161)不改 Base.ts;工作树 Base.ts 未提交改动仅 F07 两处 cleanup hook,与 F01 unique 代码零交集,无冲突 ✓。

### rev 实跑门

- tsc --noEmit: **0 错**;jest uniqueConstraintHelpers: **14/14**。

---

## 非阻塞观测(均不构成 error,不计入 issues)

1. trash 开态 divergence(int 节)——已知设计差异,关闭态等价已验证;开关一次即归一为 partial。
2. queryUniqueConstraintName 不覆盖 partial index(pg_constraint 外的 CREATE UNIQUE INDEX): 若 internal_meta 丢失且 unique 为 partial index,OFF 回填查不到名→随机 fallback 名 DROP IF EXISTS 落空→旧索引残留。常规产品流不可达: 两条启用路径(columnAdd/columnUpdate)均经 storeUniqueConstraintName(In)InternalMeta 持久化真名(int-2 实证),仅元数据被外部破坏时可达。
3. 环境噪声: 会审期间 dev server 三度重启(并行 lane 抢占 rspack dist),已带重试完成全部用例,非 F01 缺陷。

## 清理

- API 删 base(soft)后,DB 侧已彻清: schema pc3z9jjrr3yb41z 已 DROP,nc_bases_v2/nc_models_v2/nc_columns_v2/nc_sources_v2/nc_views_v2/nc_grid_view*/nc_base_users_v2/nc_audit_v2 相关行=0,`f06r4b%` 表/残留=0。临时凭证文件已删(.work 下无 lane4 凭证明文)。
