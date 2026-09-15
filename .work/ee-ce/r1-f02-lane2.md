# F02 R1 — lane2 集成测试 + 代码复审报告（commit 4b26d7a23f）

## 结论

**issues**（按严重度排序；1/2/4/5 实测复现，3 实测+代码，6 代码验证）：

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:3025 (nestedInsert) + packages/nocodb/src/services/datas.service.ts:173 + packages/nocodb/src/services/public-datas.service.ts:825`：**v1 认证数据插入路径与匿名共享表单提交路径无 per-field 权限挂点，RECORD_FIELD_EDIT 被完全绕过**。nestedInsert 是独立 insert 实现，F02 只挂了 insert.ts(baseModelInsert)/updateByPk/bulkUpdate/bulkUpdateAll/bulkUpsert/updateLTARCols。实测：nobody grant 活跃时，editor 经 `POST /api/v1/db/data/noco/<baseId>/<tableId>` 写入受限字段 → **200 且值落库**（同请求 v2 路由 403）；匿名经 `POST /api/v2/public/shared-view/:uuid/rows` 带 nobody-grant 字段值 → **200 且值落库**。建议：nestedInsert 内补 checkPermission（尊重 skipPermissionCheck；匿名路径按 enforce_for_form 语义剥离受限字段值而非 403，对齐 UI 隐藏行为）。
2. `packages/nocodb/src/db/BaseModelSqlv2.ts:10574-10590 (checkPermission) + packages/nocodb/src/models/Permission.ts:233 (insert)`：**multi-grant 无唯一性约束，裁决取 grants[0]（列表顺序第一个），顺序依赖非确定**。实测：同字段 role=creator + user[editor] 双 grant，role 行在前 → editor 403；user 行在前 → editor 200——「任一命中即过」未实现；并发创建两条 grant 实测都 200（迁移 nc_083 对 (base_id,entity,entity_id,permission) 无唯一约束，service 不拒重）。前端 isAllowed/getPermissionSummary 同样 grants[0]（usePermissions.ts:128/155，与后端同序一致但同属任意）。建议：service/DB 层拒绝同 (entity,entity_id,permission) 重复 grant，或改多 grant「任一允许即过」并同步前端。
3. `packages/nocodb/src/models/Permission.ts:330-346 (update)`：**PATCH granted_type→user 不带 subjects → 200 成功，语义变静默 deny-all**。实测：role=editor grant PATCH `{"granted_type":"user"}` → 200，随后 editor PATCH 受限字段 403（subjects 空 → evaluatePermission false）。create 有对称守卫（subjects required→400），update 没有。建议：update 中 granted_type=user 且未提供 subjects 时 400。
4. `packages/nocodb/src/models/Permission.ts:262-285 (insert) + 330-346 (update)`：**granted_role 不校验枚举，也不执行 RECORD_FIELD_EDIT.minimumRole=EDITOR（SDK PermissionMeta 钦定）**。实测：`granted_role:"bogus"` 创建 200 → 该字段对 creator/editor 全部 403（PermissionRolePower[bogus]=undefined → false）直到该行删除；`granted_role:"viewer"` 创建 200（UI 选项已过滤 viewer/commenter，API 直调可建，语义与 minimumRole=EDITOR 冲突且 summary 误导）。update 路径同样可把 granted_role 改为任意串。建议：insert/update 校验 granted_role ∈ PermissionRole 且 power ≥ EDITOR。
5. `packages/nc-gui/composables/usePermissions.ts:144-166 (isAllowed)`：**前端缺 owner 直通，与后端 isAllowed 漂移**。后端 Permission.isAllowed 对 mappedRole===OWNER 早退 true（Permission.ts 尾部）；前端 isAllowed 直接走 evaluateTableFieldPermission→evaluatePermission：owner 在 user-grant（不在 subjects）或 nobody grant 下返回 false → UI 锁图标/禁编辑，而后端 API 允许 owner 写。建议：isAllowed 前置 `currentUserPermissionRole === PermissionRole.OWNER → return true`（team subject 前端支持/后端拒建、匿名表单前端硬拒/后端不拦已见 issue 1，此条仅 owner 漂移）。

**observations（记结论，不算 error）**：
- 无新增后端 jest 用例（commit 仅跑存量 26/26）；TASK 验收清单「补/改单测」未落地（前端 wrapper 测试为 CE 既有 14/14 通过）。
- updateLTARCols 挂点（4710-4730）与 link 5 调用点（6432/6835/8717/8734/8752）代码接线正确（colId 直传 + cookie.user）；live link 测试因 v2 建链列格式未走通，标记 code-reviewed-not-live-tested。
- 进程内缓存无 TTL → 无部分过期窗口；跨实例无 Redis 时各进程缓存独立，属 NocoDB 全模型既有约束，非本功能引入。

## 语义矩阵（PATCH/POST 实测，语义钦定对照）

环境：f02r1l2-base / t1，受限字段 SecretNote（title=SecretNote，column_name=tmp，title≠col_name 故意构造），grants 经 v2 meta API。矩阵基于 `PATCH /api/v2/tables/:id/records`（数组体=bulkUpdate 路径）、单对象体（updateByPk 路径）、`POST /records`（insert 路径）。

### A. 角色语义矩阵（role grant × 用户角色 × PATCH 受限字段）

| 用户角色 | 无 grant (fail-open) | role=editor | role=creator | role=commenter | role=viewer | nobody | user=[editor] |
|---|---|---|---|---|---|---|---|
| owner（直通） | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ |
| creator | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ | 200 ✓ | 403 ✓ | 403 ✓ |
| editor | 200 ✓ | 200 ✓ | 403 ✓ | 200 ✓ | 200 ✓ | 403 ✓ | 200 ✓ |
| commenter | 403 ✓(data ACL) | 403 ✓ | 403 ✓ | 403 ✓(ACL) | 403 ✓(ACL) | 403 ✓ | 403 ✓ |
| viewer | 403 ✓(data ACL) | 403 ✓ | 403 ✓ | 403 ✓ | 403 ✓ | 403 ✓ | 403 ✓ |
| no-role | 403 ✓(base ACL) | — | — | — | — | — | — |

- role power ≥ granted → 200；< → 403：✓ 全格符合。commenter/viewer 全 403 是 base 数据写 ACL 先拦——**grants 不会给无写权限角色提权**（无越权）✓。
- owner 全 200（含 nobody/bogus/user-grant 不含己）✓ = 钦定 owner 直通。
- **nobody 语义结论**：非 owner（creator/editor/commenter/viewer）全 403 = evaluatePermission(nobody)→false + 仅 owner 早退 = **预期**，符合钦定。
- user subjects：命中 200/未命中 403 ✓；多 subject ✓；subjects 替换（PATCH 换人后旧人 403 新人 200）✓；空 subjects create → 400 ✓。

### B. 写路径覆盖

| 路径 | 无 grant | 有 grant（低于用户权力/nobody） | 通过角色 |
|---|---|---|---|
| v2 PATCH /records 单对象（updateByPk） | 200 ✓ | 403 带字段 title ✓ | creator 200 ✓ |
| v2 PATCH /records 数组 2 行含受限（bulkUpdate） | 200 ✓ | 403 ✓ | creator 200 ✓ |
| v2 PATCH /records 2 行无受限 | 200 ✓ | 200（只查变更列）✓ | — |
| v2 POST /records 单条含受限（insert） | 200 ✓ | 403 ✓ | creator 200 ✓ |
| v2 POST /records 数组含受限（bulkInsert） | — | 403 ✓ | creator 200 ✓ |
| v1 POST /db/data（nestedInsert） | 200 | **200 写入（issue 1）** | — |
| 公共表单 /public/shared-view/:uuid/rows | 200 | **200 写入（issue 1）** | — |
| 未知键 PATCH（NoSuchKey） | 200（静默剥离，未触受限列，合理）✓ | — | — |

### C. title vs column_name
title=SecretNote / column_name=tmp 构造下：title 键 PATCH → 403 ✓（mapAliasToColumn 先于 hook）；column_name 键 → 403 ✓。无键型绕过。

### D. 缓存/即时性
- 同一 editor 连续请求：grant create → 立即 403；delete → 立即 200；re-create → 立即 403 ✓（无跨请求 marker 泄漏，extract-ids 预置 `[]` 由 `__permissionsLoaded` marker 修复，fail-open 实测 200 ✓）。
- NocoCache 形态：list 键 `PERMISSION:base:<id>` 存 id 字符串数组（sadd 语义对字符串数组成立）+ 每行独立对象键 + `['NONE']` 空集哨兵——符合仓内 appendToList 惯例 ✓。无 TTL → 行键与 list 键同写同删（evictPermissionCache 双删），无部分过期窗口 ✓。
- 跨 base：base2 的 grant 不出现在 base1 list（0）✓；跨 base PATCH/DELETE grant → 404 ✓；跨 base entity_id create → 400（Column.get 上下文限定）✓。
- base 删除：deleteByBaseId 生效——dup base 删除后其 0 残留；全库 `nc_permissions` 孤儿行（base 已删）= 0 ✓。

### E. multi-grant / 并发
- 同字段双 grant 顺序裁决见 issue 2：role=creator 先 → editor 403；user[editor] 先 → editor 200。
- 并发 2 个 create 同字段 → 双双 200，字段上 4 条 grant 并存（含历史残留）→ creator 也 403（grants[0]=bogus 行）——顺序依赖实证。

### F. 复制/导入（skipPermissionCheck + F07 回归）
- duplicateBase（nobody grant 活跃时执行）→ 成功，全部行含受限字段值复制 ✓（F07 快照/恢复不受 F02 影响）；副本 base 不复制 permission 行（0）✓。
- skipPermissionCheck=true 消费点（import.service ×3、bulk-alias 透传）在 bulk insert 挂点处尊重 ✓；bulkUpdateAll 用自身 skipValidationAndHooks 门（select 重写等 trusted caller）一致 ✓。

### G. 管理面/ACL/校验
- editor/commenter：permissionCreate/List → 403 ✓；owner：v1+v2 meta list → 200 ✓。
- 无效输入：bad entity / 不存在 column / 非法 permission key / FIELD+TABLE_RECORD_ADD / 非法 granted_type / role 缺 granted_role → 全 400 ✓。缺口见 issue 3/4（update 对称性、granted_role 枚举/minimumRole）。

### H. 前端
- usePermissions：懒加载 per-base（loadedFor 防重入，失败回滚）、base 切换清空重拉、getPermissionSummary 映射 ✓；drift 点见 issue 5（owner）。
- wrapper vitest `test/table-field-permission.test.ts` 14/14 ✓。

## 测试残留（.work 内记录，非 git）
- 账号 f02r1l2-*（owner 提权 super）；base `f02r1l2-base`（含自链系统列 `t1`——删除被 system column 守卫拒，为测试产物非实现缺陷）；`f02r1l2-form` 表单视图残留于该 base。
- 已清理：全部 grants（base1=0）、dup base（已删）、v1 绕过行（已删）；全库 nc_permissions 孤儿行 0。
- 脚本：.work/ee-ce/tmp-f02r1l2/{setup,matrix,matrix3}.sh（矩阵以 matrix3.sh + 后续内联探针为准；matrix.sh 的 404 行是 v2 无单行 PATCH 路由所致，非用例有效行）。
