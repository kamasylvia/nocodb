# R6 F02 复审报告 — lane3（收敛第 5 轮）

## 结论

**PASS**（0 error。下述 observations 均经实测/源码走查判定非 F02 引入或无行为影响，不计 error）

## R5 修复验证（commit 10e8d92729，本轮重点）

| # | 用例 | 结果 |
|---|---|---|
| 1 | create `granted_type:nobody` + subjects → 400 `subjects are not allowed on nobody grants` | ✅（validateGrantShape 共享路径，DB 零写入） |
| 2 | update 同载荷 → 400 同文案 | ✅ create/update 对称达成 |
| 3 | clean nobody create / update → 200 | ✅ |
| 4 | **updateLTARCols title 键载荷拦截**：v3 bulk update `{"id":1,"fields":{"ChildLink2":[...]}}`（title 键 link 列 + nobody grant）editor → **403 "You don't have permission to edit the field ChildLink2"** | ✅ 三键匹配（`c.title === cn`）使 wrapper 守卫从死钩变活，实测拦截 |
| 5 | 对照：owner 同 v3 title 键 link 载荷 → 200 且 link **真实落库**（GET links 验证 child 已挂） | ✅ 该路径确实产生 link 写，守卫只拦无权者 |
| 6 | v3 insert title 键 link editor → 403；owner → 200 + 落库 | ✅ |

注：v3 updateLTARCols 路径实际有两层守卫（BaseModelSqlv2 wrapper R5 三键版 + LTARColsUpdater 内部 title 版，后者早轮已加），行为等价；R5 修复点为 wrapper 层三键匹配，源码走查 + 403 实证均确认激活。

## 写入路径扫描（Secret/ChildLink2 = nobody grant，editor）

受限全 403 / 干净全 200：

- v2 PATCH 受限 403 / 干净 200；v2 POST 受限 403 / 干净 200
- v1 insert 受限 403 / 干净 200；v1 PATCH 受限 403
- bulk insert（v1 bulk）受限 403 / 干净 200；bulk update 受限 403；bulkUpdateAll 受限 403
- v3 bulk update 受限字段 403 / 干净 200；v3 insert 受限 403 / 干净 200
- link 系：addChild 403（owner 201 + 落库）、addLinks 多值 403、removeChild 403、v3 link POST 403
- move（POST /records/:rowId/move）→ 201：仅写 Order 列，Order 无 grant，不涉及受限字段——**事实记录：move 天然不触字段检查，预期即 2xx**，非漏拦
- ACL：editor list 200（editors+ 可读）/ editor PATCH 403（creator+）
- 重复 grant（同 entity+entity_id+permission）→ 400

## skip 通道

- F07 快照：grants 在场建快照 → `completed`，快照 base 数据完整复制（8 行，含受限字段值）→ duplicateBase 复制链未被自身 grant 拦截（insert.ts `!skipPermissionCheck` 守卫 + import.service 三处 `skipPermissionCheck: true` 走查一致）
- 权限行不随快照复制（快照 base permissions = []）——fork 语义事实记录
- undo：v1 insert `?undo=true` 携受限字段 editor → 403（undo 是用户写重放，不豁免，正确）

## 回归

- 无 grant CRUD（Child 表）：PATCH/POST/DELETE/GET 全 2xx（fail-open 保持）
- F05 variables list/create（key/value）200；F07 snapshots list 200；F08 bases list 200；F10 dashboards list 200
- 后端 `tsc --noEmit` = 0 错；jest 26/26；nc-gui vitest table-field-permission 14/14
- F02 触碰文件 console.* 扫描（26 个 diff 文件）：**0 残留**

## 代码复审（10e8d92729 + 累计 diff 46e5c81727..HEAD）

- **三键匹配误匹配风险**：pg 实测 column_name = title 小写 slug（Title→title）。跨列碰撞需「A 列 title 恰等于 B 列物理名」——title 表内唯一 + slug 去重使该场景近乎不可达；`c.id === cn` 键需客户端以 nanoid 作字段名，非真实 API 面。find 顺序确定，同键双命中映射同列 Set 去重。判定：无实际误匹配面，observation 级。
- **update() subjects 重建/nobody 清理顺序**：validate → metaUpdate（切 nobody 时 granted_role=null）→ data.subjects 提供时 delete+rebuild → targetType=nobody 无条件再 purge → get() 返回。`{'granted_type':'user','subjects':[]}` 400（空数组非 nullish，`?? existing` 不回退）、`{'granted_role':null}` 于 role grant 400（R4 终值语义）、role→user 无 subjects 400、nobody 残留 subjects 清理覆盖 subjects 键缺省场景。顺序正确。
- skip/raw 通道走查：bulkUpsert `raw:true` 无外部调用方；bulkUpdate raw 无调用方；bulkUpdateAll `skipValidationAndHooks:true` 仅 columns.service 列转换内部路径；bulkInsert bulk 钩受 `!skipPermissionCheck`（insert.ts:345）；单条 insert 钩不受豁免（用户写恒查）——豁免面与实现一致。

## Observations（非 error）

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:6013`（afterUpdate）— **bulkUpsert clean 更新分支 500** `Cannot read properties of undefined (reading 'Id')`（POST /api/v1/db/data/bulk/noco/:base/:table/upsert 携已有 Id）。诊断：无 grant 的 Child 表 + owner token 同样 500 → 与 F02 无关的上游 CE 缺陷（F02 钩子只读不变异状态，且该路径 grant 为空时钩子直通）。upsert 纯插入 201 正常。建议：另立 upstream 修复项，不入 F02 计数。
2. `packages/nocodb/src/db/BaseModelSqlv2.ts:4727` updateLTARCols wrapper 守卫无 raw/skip 豁免——当前全部调用方均为用户写路径（bulkUpsert/v3 bulkUpdate），无实际过拦；未来若接入 trusted-internal 调用方需补豁免。
3. 列删除不级联删 nc_permissions 行（我方 fixture 删坏列后 grant 残留）。无行为影响（新列新 id，旧 grant 永不匹配；且删列本身需 creator+）。hygiene 级。
4. wrapper 内 `this.model.getColumns(this.context)` 用缓存模型 context 而非 req.context——getColumns 按 model 缓存，今日无行为差异，一致性 note。

## 覆盖面声明

- API 实测 40+ 请求（v1/v2/v3 数据面 + permissions CRUD + link + bulk + move + undo + snapshot）
- DB 直查：nc_permissions/nc_columns_v2 交叉验证（仅 nocodb-dev）
- 测试数据：base `p7upgw7w9hi9s1e`（f02r6l3-base），账号 f02r6l3-owner/editor@t.example
- 未覆盖：reorderLink（controller 注释明示无公开 REST 路由，仅 internal-operations API）；shared/public form 匿名提交端到端（enforce_for_form 路径由 R1-R5 各轮覆盖，本轮以 checkPermission 源码走查 + 前轮结论为准）
