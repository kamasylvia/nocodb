# r4-f02-lane3.md — F02 R4 轮 lane3（收敛第 3 轮）：写入路径覆盖面 + 回归终审

## 结论

**PASS**

（无 error 级发现。2 条非阻塞观察项见末节，均有兜底或归因非 F02 引入，不计违反。）

## 覆盖面

审查对象四 commit：4b26d7a23f（实现）/ e85a421d92（R1）/ 3b9dcbdbc6（R2）/ a8fc2c2966（R3 update nobody 不变量重构）。测试实例：`nocodb-dev`，base `p9pnhozzh0yq274`（Main 表 title≠column_name 形状 + ChildLinks HasMany link 列 + Child 表）与 base `pz7h3navduqmcpc`（user-grant 链），测试号 `f02r4l3-*`（owner super / editor），测试后全部清理（删 base 验证 permission/subjects 行清零、测试号 0 残留）。

### 1. R3 修复验证（a8fc2c2966）

| 断言 | 结果 |
|---|---|
| PATCH `{granted_type:"nobody", subjects:[...]}` | **400** `subjects are not allowed on nobody grants` ✓ |
| PATCH `{granted_type:"role"}` 无 granted_role | **400** `granted_role is required for role grants` ✓ |
| 两个 400 后状态不污染（grant 仍 nobody/role=null） | ✓（GET list 复核） |
| 有效转换 nobody→role:editor | **200** ✓ |
| 转回 nobody（清理通道）| **200**，`nc_permission_subjects` 该 id 0 行 ✓ |
| 已存在 nobody grant 再加 subjects（`{subjects:[...]}` 不带 granted_type）| **400** ✓（R3 前置校验对「类型不变、仅加 subjects」同样生效） |
| v1 插入受限字段（`POST /api/v1/db/data/noco/:baseId/:tableId` 含 Secret）| **403**，行未落库（totalRows=0）✓ |

### 2. 写入路径扫描（editor，Secret=nobody grant / EdOnly=role:editor grant）

受限路径全 403：

- v2 insert 单条含 Secret：403
- v2 insert 数组（2 行含 Secret）：403
- v2 PATCH 单条 `{Id,Secret}`：403
- v2 PATCH 数组含 Secret+EdOnly：403
- v2 嵌套 insert（`ChildLinks` 内联 + Secret）：403
- v1 单条 insert 含 Secret：403
- v1 bulk insert / bulk update / bulkUpdateAll / bulkUpsert 含 Secret：403 ×4
- v1 单条 PATCH 改 Secret：403
- 受限 link 列（临时给 ChildLinks 上 nobody grant）：v1 addChild/removeChild 403；v2 addLinks（body `[2]`）/removeLinks 403；v2 嵌套 insert 走受限 link 列 403
- updateLTARCols 路径：v2 records PATCH 剥离 LTAR（payload 不生效、link 未变，无绕权面）；v1 upsert 内联 link 仅 V3 生效（`nestedCols` gated on `apiVersion===V3`），link 值被剥离不写 = 无绕权面；V3 到达 updateLTARCols 时按 title/column_name 双键由上游 `ltar-cols-updater.ts:45-49` 预埋 guard（title 匹配）与 F02 挂点（`BaseModelSqlv2.ts:4727`，column_name 匹配）互补拦截

干净路径全 200（对照）：

- v2 insert 单条/数组、PATCH 单条/数组、嵌套 insert、move：200/201
- v1 单条 insert/PATCH、bulk insert、bulkUpdateAll、upsert insert-only：200/201
- v1/v2 link 系（无 grant fail-open）：addChild/addLinks/removeChild/removeLinks 200/201
- v1 PATCH 改 EdOnly（editor 满足 role:editor）：200（role grant allow 侧）
- v2 insert 含 EdOnly：200

undo 通道（`?undo=true`，不豁免权限 = 正确安全语义）：

- editor 干净字段 undo：200
- editor 受限字段 undo：403（undo 不提权）
- owner 受限字段 undo：200（owner 直通）

user-grant 全链路（R3 转换链端到端，base2）：

- nobody 期 editor insert UserOnly：403
- PATCH nobody→`user:[owner]`：200；editor insert 403 / owner insert 200
- PATCH subjects 追加 editor：200；editor insert **200**
- 空 id subject（`{type:"user",id:""}`）被 400 拒（validateGrantShape 生效）
- 回退 nobody：`nc_permission_subjects` 行数 0（清理在 subjects 重建之后执行，顺序正确）

### 3. skip 通道

- **F07 快照**（owner，`POST /api/v2/meta/bases/:baseId/snapshots`）：processing→completed，快照 base Main 表 12 行，Secret/EdOnly 数据完整（seed1 Secret=s1 / EdOnly=v1pe 原值保留）— duplicateBase 内部复制免检生效
- **duplicate**：快照即 duplicateBase 全量复制（已验）；表级 duplicate 在本 CE 版本无独立 GUI/API 入口
- **undo**：见上节三态

### 4. 回归

- 无 grant CRUD（editor）：insert/PATCH/bulk/delete 全 200（fail-open 契约保持）
- F05：editor 建 variable 403（creator+ ACL 保持）；owner 建（key/value 形状）200
- F07：快照列表 200；快照创建/完成（本测）
- F08：base list 200
- F10：owner 建 dashboard 200
- `tsc --noEmit`：exit 0
- `pnpm test`（jest）：**26/26 passed**（2 suites：uniqueConstraintHelpers.Fork / baseVariableValidators.Fork）

### 5. console.log 零残留

- F02 触碰文件（`git diff 46e5c81727..HEAD` 全清单）grep `console.(log|debug|info|warn|error)`：命中行全部为上游原生（父 commit 前后数量一致：ColumnMenu.vue 1/1、useViewData.ts 3/3、public-datas.service.ts 4/4、BaseModelSqlv2.ts warn 3/3）；**F02 diff 新增 console 行 = 0**
- 受限写请求（403）后 dev server 日志（`.work/ee-ce/logs/backend.log`）新增 0 行，无 F02/permission 输出

## 代码复审（a8fc2c2966 + 累计）

- `update()` 重构（Permission.ts:300-419）：
  - 三个 resolved-type 不变量（nobody+subjects / role 缺 granted_role / user 缺 subjects）全部在**任何写操作之前**校验，400 后 grant 状态零污染（实测复核）
  - 空载荷 PATCH `{}`：updateObj 为空跳过 metaUpdate，targetType=existing，user grant 保留 subjects 校验放行（`data.subjects ?? existing.subjects`），无副作用
  - subjects 重建（delete+insert）在前，nobody 清理（delete）在后 — 「regardless of payload order」成立，实测 user→nobody 后 subjects 0 行
  - nobody 转换清 granted_role=null（防 stale role）
  - `data.granted_role ?? existing.granted_role` 处理 user→role 之外的转换正确；role→role 无 payload 变更时不误 400
- 跨 base 隔离：`Permission.get` 走 `metaGet2`（meta.service.ts:701 `contextCondition` 加 `base_id=` 条件）+ service 层 `existing.base_id !== baseId` 双重归属校验；`metaUpdate`（:968）同样带 contextCondition — update/delete 均无跨 base 读写面
- extractProps 白名单（update 仅 granted_type/granted_role/enforce_*）：entity/permission 不可变，无注入面

## 观察项（非阻塞，不计违反）

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:4727`（updateLTARCols 的 F02 挂点）用 `fieldPermissionEntityIds`（按 `column_name` 匹配），而到达该函数的 datas 键通常为 title 形式 → title≠column_name 表上该挂点提取为空集、自身不拦；实际拦截由 `ltar-cols-updater.ts:45-49` 上游预埋 guard（`col.title in d`，title 匹配，checkPermission 实装后自动激活）承担；column_name 键场景则由 4727 兜底 — 两 guard 互补后覆盖完整，无权限绕过。建议后续轮把 4727 注释补充双键互补语义（现注释暗示它是唯一防线，与实际不符）。
2. `v1 upsert` 更新分支 POST `/api/v1/db/data/bulk/noco/:baseId/:tableId/upsert` 对已存在行 upsert（无论 payload 含不含 link 列）稳定 500（`afterUpdate` BaseModelSqlv2.ts:6013 `Cannot read properties of undefined (reading 'Id')`，经 4171 调用）。归因：blame 显示该调用块与 6013 行最后实质变更分别为 58ed76ab44（2026-05-15 上游同步）与 2681b116ac（2025-01-10 上游 Audit v1），**F02 四 commit 未触碰**；且受限字段场景权限 403 在 500 之前正确抛出（`[{Id,Secret}]` → 403 非 500），insert-only 分支正常 201。属上游遗留缺陷，与 F02 无关，建议另行立案。

## E3 外部限制

无。
