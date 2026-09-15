# r2-f03-lane5.md — F03 R2 收敛轮（lane5：功能全量集成测试 + 整个 diff 代码复审）

审查对象：7b10716231（F03 实现）+ 2f5a57b0d3 / e1e996283c / 0a3e5fdab4（R1 修复）。
环境：dev server :8080（含修复）、qnap.elf-balance.ts.net:5432/**nocodb-dev**、新建隔离 base `pyibe0yitbp0cr8`（owner/editor/creator 三号，全 API 建，权限行全走 API）。

## 结论

**issues（1 error + 3 minor）**

1. **ERROR — `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts`（ExtractIdsMiddleware.use() 新路径，约 :135-460；对照 AclMiddleware F03 检查块 :1378）：v1 data 路由族 TABLE_VISIBILITY 遮蔽未生效，R1 修复（2f5a57b0d3）写在了不会执行到的分支。**
   - 根因：`use()` 按「params 是否含 baseId/baseName」分两条路。v1 data 路由族（`/api/v1/db/data/:orgs/:baseName/:tableName`、bulk `.../bulk/:orgs/:baseName/:tableName[/upsert|/all]` 等）带 `:baseName` → 走 `use()` **新路径**；该新路径解析 `tableId = params.tableId || params.modelId || params.tableName || query.tableId` 后仅设 `req.ncSourceId`，**从不设置 `req.context.ncTableId`**（ncTableId 只在 `legacyExtractIds()` 内赋值，:1100 与 R1 兜底 :1107）。AclMiddleware 的 F03 检查条件是 `req.context?.ncTableId` → v1 data 路由恒缺 → 整块跳过。R1 的 tableName 兜底解析加在 `legacyExtractIds()` 末尾，而 v1 data 路由永不进入该 else 分支 → 修复无效。
   - 实测（VISIBILITY nobody on TableB，editor）：v2 data GET/POST/PATCH/DELETE/count 全 404 ✓（这些路由无 baseId param → 走 legacyExtractIds → 拦截正常）；**v1 `GET /api/v1/db/data/noco/:baseId/:tableId`（dataList）返回 200 且吐出隐藏表全部行**；v1 row GET 同样返回隐藏行（灌 secretA/secretB 后实测泄露）。owner 直通正常。
   - 上游归属佐证：use() 新路径结构与 `params.tableName` 纳入 tableId 来自上游 mertmit `c1d409a82b fix: extract middleware`（F02 之前），但「v1 路由绕过 fork 新增的 VISIBILITY 检查」本身是 F03 面的覆盖缺口——fork 把检查挂在 ncTableId 上而 ncTableId 在该路由族恒缺。
   - 建议：在 `use()` 新路径 `else if (tableId)` 分支 `Model.get` 成功后补 `tableIdToCheck` 等价处理（`req.context.ncTableId = model.id`；viewId 分支映射 view 所属 model 同理），或把「按 params.tableName 解析 ncTableId」的兜底从 `legacyExtractIds()` 末尾提升到 `use()` 两路汇合处（`additionalValidation` 前后均可），使 AclMiddleware 检查对所有携带表 id/别名的路由族一致生效。

2. **minor — `packages/nocodb/src/models/Permission.ts` update()（R5/R3 段，约 :330-395）：NOBODY 目标的 granted_role 卫生清理不彻底，已落库 granted_role 可残留或被后续 PATCH 写入脏值。** 实测序列：role:creator grant → PATCH `{granted_type:"nobody","granted_role":"viewer"}` → 200（注释宣称 reject，实现是 delete updateObj.granted_role 后继续）→ PATCH `{granted_role:"viewer"}`（不带 granted_type）→ 200 且 `nc_permissions.granted_role='viewer'` 落在 nobody 行（psql 确认）→ PATCH `{granted_type:"nobody"}` 后 granted_role 仍残留（updateObj 无此键可删，不 force 落库清空）。权限语义无损（SDK nobody 判定不读 granted_role），但与「NOBODY 清 subjects/granted_role」的 R1 修复宣称不符且落库脏数据。建议：`targetType === NOBODY` 时 UPDATE 显式置 `granted_role = null`（或 validateGrantShape 对 NOBODY 目标拒绝 granted_role 键存在）。

3. **minor — `packages/nc-gui/components/dlg/Table/Permissions.vue` save()（约 :225-260）：SPECIFIC_USERS 未选人时 buildPayload 返回 undefined → 该 key 静默跳过，但流程继续走 `message.success` + 关弹窗**，用户感知「已保存」而该项实际未写（服务端「user grant 必须 subjects」守卫正确，UI 侧静默不一致）。建议跳过项 toast 提示或无选中时禁用 save。

4. **minor — `packages/nc-gui/components/dlg/Table/Permissions.vue` loadCurrent()（OPTION_FOR_ROLE 映射，约 :88-96）**：VISIBILITY grant 的 granted_role 若为 editor/commenter（API 直设合法，≥ viewer minimumRole）无法映射到 visibilityOptions（仅 viewer/creator 两档），fallback EDITORS_AND_UP 不在选项集 → radio 全不选。显示缺陷，非安全。

**E3（外部/环境限制，不算 error，均有诊断证据）**

- v1 data 路由的 `:tableName` **title 形式**在本实例整体 404（owner 亦然）：上游 c1d409a82b 的 use() 新路径 `Model.get(tableId)` 只按 id 查表，title 直接 `tableNotFound`（遗留 base lane5-f03-r1 同样复现）。与权限无关；副作用是 v1 title 形式天然全遮蔽。本轮 v1 面测试全部改走 tableId 形式（中间件与 service 均可解析）。
- bulkUpsert **纯 update 批**在本实例 500（上游既有）：owner、无 grant editor 同 payload 均 500（`/api/v1/db/data/bulk/noco/:baseId/:tableId/upsert`，`[{"Id":20,"Name":"..."}]`），与权限检查无关（fail-open 下同样 500，F03 的 `if (toInsert.length)` hook 根本未执行）。混合批（含新行）则正确 403 → 「拆分后只查 toInsert」的挂点位置语义正确，纯 update 批的「不误伤」只能由代码位置确认（`toInsert.length` 守卫在），运行时验证被上游 500 阻断。
- 一次 editor token 401（重新 signin 恢复）；zsh sandbox 间歇 "failed to change group ID"（拆单命令重试恢复）。

## 逐项结果（集成测试，全 API 实测）

| # | 项 | 结果 | 证据（请求 → 状态码） |
|---|---|---|---|
| 1 | fail-open 基线：无 grant editor insert/delete/update | PASS | POST/PATCH/DELETE /records → 200,200,200 |
| 2 | ADD nobody：editor v2 single | PASS | 403 "You don't have permission to create records in TableA" |
| 3 | ADD nobody：creator | PASS | 403（nobody 语义 = 仅 owner，符合 SDK 契约） |
| 4 | ADD nobody：owner | PASS | 200 |
| 5 | ADD nobody：editor v2 bulk | PASS | 403 |
| 6 | ADD nobody：editor v1 single（tableId 形式） | PASS | 403 |
| 7 | DELETE nobody：editor v2 bulk delete / v1 delByPk / v1 bulk delete / bulkDeleteAll | PASS | 403 ×4（同一 message 族） |
| 8 | DELETE nobody：owner / creator | PASS | 200 / 403 |
| 9 | ADD role:creator：editor 403 / creator 200 | PASS | 403 / 200（role power 分界正确） |
| 10 | VISIBILITY nobody：editor 表列表 | PASS | TableB 从 `GET /tables` 消失 |
| 11 | VISIBILITY nobody：editor 直连 meta / v2 GET/POST/PATCH/DELETE/count | PASS | 404 ×6（tableNotFound，遮蔽格式与不存在表一致） |
| 12 | VISIBILITY nobody：**v1 data 路由（tableId 形式）** | **FAIL（error-1）** | dataList 200 泄露全部行；row GET 泄露 |
| 13 | VISIBILITY nobody：creator / owner | PASS | 列表可见 / 数据 200 |
| 14 | SPECIFIC_USERS（DELETE user grant → editor）：匹配 editor 删 200 / creator 403 / owner 200 | PASS | 200/403/200 |
| 15 | VISIBILITY role:viewer：editor 恢复可见（列表+data+v1 data） | PASS | 200 ×3 |
| 16 | Everyone = 删 grant 行往返：DELETE grant → editor 200 | PASS | 200 |
| 17 | 重复 grant (entity,entity_id,permission) | PASS | 400 "already exists" |
| 18 | 跨 base 表 entity_id | PASS | 400 "Table ... not found" |
| 19 | field entity + TABLE key | PASS | 400（配对校验，R1 项） |
| 20 | role 缺 granted_role / 非法 granted_role / viewer 低于 ADD minimumRole / 非法 permission key / user 缺 subjects / nobody+subjects | PASS | 400 ×6（create 侧，D4'-D8） |
| 21 | update 侧对称：granted_role null / nobody+subjects / user 无 subjects | PASS | 400 ×3（U1/U2/U3） |
| 22 | update：bogus granted_role on nobody / 脏值残留 | **minor-2** | 200 且残留落库 |
| 23 | F02 multi-field any-deny：editor PATCH 含受限 Name 字段 403 / 不含 200 | PASS | 403 / 200（entityIds 数组任一 deny） |
| 24 | bulkUpsert：混合批（含新行）403 | PASS | 403 |
| 25 | bulkUpsert：纯 update 批不误伤 | E3 | 上游既有 500（owner/无 grant 同现），代码挂点位置正确 |
| 26 | 公共表单 TABLE_ADD：eff 默认 true 403 / false 200 / 翻回 true 403 | PASS | 403/200/403 |
| 27 | 公共表单 FIELD（RECORD_FIELD_EDIT role:creator）：eff true 403 / false 200 且值落库 | PASS | 403 / 200（`{"data":"{...}"}` 包裹格式） |
| 28 | fail-open：删 grant 后下一请求放行 | PASS | 200 |
| 29 | 回归 F05 变量 list+create | PASS | 200/200 |
| 30 | 回归 F07 快照 list / F10 dashboard list | PASS | 200/200 |
| 31 | 回归 F08/ACL：非协作者访问 base 表与数据 | PASS | 403/403 |
| 32 | ACL：editor POST grant | PASS | 403（creator+ 才可写） |
| 33 | permissionList editor 可读（锁标/表单隐藏依赖） | PASS | 200（v1+v2 双路径） |
| 34 | 后端 tsc --noEmit | PASS | exit 0 |
| 35 | 后端 jest Fork 桶 | PASS | 2 suites / 26 tests passed |
| 36 | 前端 vitest table-field-permission | PASS | 14 tests passed |

## 代码复审（整个 diff：4b26d7a23f^..HEAD，27 文件 +2256/-71）

- `fieldPermissionEntityIds`：Set 去重 + system/pk/FK/isSystemColumn 四重过滤 + column_name/title/id 三键全收集 ✓（R6 防劫持语义正确：find-first 改全收集，over-block 是安全方向）；空 payload 快路径 ✓
- `checkPermission`：owner 直通 → req.context 权限清单（R1 修复的 context 驻留正确：mark 在 req.context 而非 this.context，避免 model 级缓存实例的 stale 空清单）→ 空清单 fail-open → 逐 entityId multi-grant any-deny（顺序无关）→ 匿名仅 form-context 且 grants 全 eff=false 才豁免 ✓；deny 文案 per-permission 泛化（TABLE → create/delete records in <title>，不泄漏 id）✓
- `update()` 三守卫顺序：validateGrantShape（resolved type + 'granted_role' in data 显式 null 语义）→ enum 校验 → resolved-type 不变量（nobody+subjects / role 缺 role / user 缺 subjects）全部先于写 ✓；subjects 重建先删后插 ✓；nobody 清理缺陷见 minor-2
- `validateGrantShape` 共享校验（create/update 同源）：enum、minimumRole（PermissionRolePower 比较）、subjects 形状、nobody+subjects 互斥 ✓
- extract-ids：R1 的 tableName 解析逻辑本身正确（getByAliasOrId + model 存在才设），**位置错误**（放 legacyExtractIds 末尾，v1 data 路由不走）→ error-1；VISIBILITY 检查块本身（空清单短路、isServiceUser 豁免、404 遮蔽、匿名回落 default）实现正确
- permissions.service：TABLE entity 三 key 白名单 + Model 存在/base 归属/synced 拒配 ✓；重复键检查先于 shape 校验（D4/D7 首测撞重复消息——顺序使错误消息不精准，非缺陷）
- 挂点覆盖：insert single/bulk（`!skipPermissionCheck` 包裹，import/copy/snapshot 免检通道生效）✓、nestedInsert（isFormContext）✓、bulkUpsert（拆分后 toInsert 行）✓、delByPk/bulkDelete/bulkDeleteAll ✓、data-table.service :398 失实注释已修 ✓、public-datas isPublicForm flag ✓
- 前端：usePermissions（per-base guard + force 语义 + base 切换清态 + owner 直通同步后端 + evaluateTableFieldPermission 共享决策）✓；useExpandedFormStore 去 isEeUI 短路 ✓；Node.vue/View.vue/Details.vue/ColumnMenu gate flag 化 ✓；grid/Table.vue ADD 消费补齐 ✓；useViewData lazy getter（R1 冻结态修复）✓；Content.vue 表级摘要 + F03 占位替换 ✓
- 探针/残留：F02/F03 diff 内 console.log/debugger 0 处（extract-ids :1164 的 console.log(e) 属上游 69a29568c7 sync，非本 diff）；错误消息无内部 id/stack 泄漏；权限行测试全走 API 无 psql 直写伪影

## 附注

- 前一轮 lane5 的 base（lane5-f03-r1 等）未动，本轮全部使用新建隔离 base `pyibe0yitbp0cr8`（TableA=mh8nffqz1b17ec3 / TableB=mg8lw8o2kdedvvm），现场保留供修复轮复核 error-1。
- 测试账号（.work/ee-ce/lane5-env/accounts.txt）；DB 凭证临时文件已删。
