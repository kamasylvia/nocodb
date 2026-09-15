# r8-f01-lane4（第 8 轮收敛确认，第 4 路：DDL/跨库 int + rev）

范围：F01 commit 744d3161（HEAD 6ab23da0，工作区含 F07 未提交改动一并核冲突）。int 全实测 PG（nocodb-dev，pg8000 直查 + dev API :8080，专用账号 f06r8a2@ce-ee.local 提权后执行，资源前缀 f06r8a2_，测后已删：base×3 删除 + 6 schema cascade drop，残留表 0）。

## 裁决：PASS

（int 32/32；rev 三文件零 error；实跑门 tsc 0 + jest 14/14。无必修项。）

## int（集成测试，PG，全实测）— PASS

int1 建表路径 vs 加列路径 unique 索引形态（pg_indexes 直查，base 专属 schema）：

- 建表路径（tableCreate unique:true）：`f06r8a2_tc_c1_key`，全量（非 partial）unique index，`CREATE UNIQUE INDEX f06r8a2_tc_c1_key ON <schema>.f06r8a2_tc USING btree (c1)`；internal_meta 为空（PG 内联 UNIQUE 自动命名，可接受）。
- 加列路径（columnAdd unique:true）：`uk_<base>_<model>_<col>`，partial unique index，`WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`；index 名 == nc_columns_v2.internal_meta.unique_constraint_name 一致。
- 两路径形态差异（全量 vs partial）符合已知 fork 设计；trash 关闭态行为等价已验证即 PASS：
  - duplicate insert：两路径均 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`，error body 含 fieldName + value
  - NULL,NULL：两路径均 200/200
  - 空串重复：两路径均 400 且 `value: ''` 取自 payload

int2 constraint 名管理 开→关→开：

- 开→关：PATCH unique:false 200；unique index 消失（pg_indexes 0 行）；pg_constraint 无 uk_ 残留；关后 dup insert 200（约束确已解除）
- 关→开：先清 dup 行后 PATCH unique:true 200（不清则 enable-time duplicate pre-check 400 拦截，见观察项 2）；重建索引存在，名 `uk_<base>_<model>_<col>` == internal_meta.unique_constraint_name 一致；重建后 dup insert 400 拒（约束实际生效）

int3 布尔归一 / 校验矩阵 / 错误体（11 项）：

- columnAdd unique:1（number）→ 400 `The unique flag must be a boolean value`
- columnUpdate unique:'true'（string）→ 400 同上
- columnAdd unique:'false' / 'yes'（string）→ 400（入口拒绝，无静默翻转）
- columnAdd unique:true / false / 缺省 → 200 正常建列
- tableCreate columns[].unique:'false' → 400（ajv schema 拒绝）
- 全程无 5xx；无 console 500

## rev（代码复审）— PASS

1. `packages/nocodb/src/db/sql-client/lib/pg/PgClient.ts`
   - tableUpdate unique 段（~2588-2640）：drop 分支先查 internal_meta、缺失时 `queryUniqueConstraintName` 回填 `oldColumn.internal_meta` 后由 `getUniqueConstraintName(o,t)` 取用——internal_meta 与 DDL DROP 目标名一致；JSON string/object 双形态容错正确。
   - `queryUniqueConstraintName`（~3441）：pg_constraint contype='u' 单列限定、schema 显式参数化、异常吞错返 null（走 fallback），无注入（参数化查询）。
   - drop 分支 DROP CONSTRAINT IF EXISTS + DROP INDEX IF EXISTS（schema 限定）双保险；addUniqueConstraintToQuery 内先 DROP 再 CREATE，幂等。
2. `packages/nocodb/src/db/sql-client/lib/mysql/MysqlClient.ts`
   - DROP INDEX 移除（[CE-EE] R1 fix ~2657）安全：两处 `addUniqueConstraintToQuery` 调用点（change=1 ADD COLUMN ~2717、change=2 加约束 ~2736）均仅在旧列非 unique 或新列场景触发，索引不可能已存在，不会 1091；方法入口 `!n.unique` 短路。
   - drop 分支保留 DROP INDEX（MySQL unique 即 index），internal_meta 回填 + `queryUniqueConstraintName`（information_schema.STATISTICS NON_UNIQUE=0）与 PG 版对称。
3. `packages/nocodb/src/models/Base.ts`（工作区 F07 未提交 diff +7 行）
   - 双挂钩：softDelete（L457）与 delete（L707）各插 `BaseSnapshot.cleanupByBaseIdWithCopies`。
   - 幂等成立：cleanup 先 list（登记行首次即删）→ 二次调用 rows 空 no-op；副本 base 无登记行 → 副本 softDelete 递归一跳终止（list(snapshot_base_id) 空）；副本 softDelete 异常被 catch 吞、登记行仍清。
   - 与 F01 无冲突：F01 不触 Base.ts；F07 清理 hook 不碰 unique 相关路径。

实跑门：

- `npx tsc --noEmit`：exit 0，无输出（含工作区 F07 改动一并检查）
- `npx jest uniqueConstraintHelpers`：14/14 passed，1 suite

## 观察项（非 error，不计违反）

1. **形态漂移**：is_meta base 表在 开→关→开 后索引从建表时全量 `_key` 变为重建 partial `uk_`（重建走 columnUpdate → addUniqueConstraintToQuery partial 路径，表含 __nc_deleted）。trash 关闭态行为等价（本实测），软删态 partial 为 fork 设计意图。同表混合形态一致性仅在有 trash 软删行时表现差异。
2. **enable pre-check 语义**：关闭约束后插入的重复行不清除则重启用 400（`Found N duplicate values`）。pre-check `whereNotNull` 排除 NULL（NULL×2 不拦，与索引行为一致），空串计入（GROUP BY 语义）。防御性正确行为，测试脚本已适配。
3. **partial index 关闭的 internal_meta 依赖**：partial unique index 不入 pg_constraint，`queryUniqueConstraintName` 查不到；关闭依赖 internal_meta 持久化名（正常路径均有，nc_columns_v2 落库）。仅当 internal_meta 异常缺失时 fallback 随机名 DROP IF EXISTS no-op 可致索引残留（理论边界，未复现，不入 issue）。

## 附：过程产物

- 测试脚本/状态：`.work/ee-ce/lane4/`（dbq.py、dbenv.sh、int_main.py、int_state.json）；tsc/jest 日志 `/tmp/lane4_tsc.log`、`/tmp/lane4_jest.log`
- 专用账号 f06r8a2@ce-ee.local（dev 库提权 org-level-creator,super）保留供下轮复用
