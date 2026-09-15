# F03 Data permissions — R3 终局收敛轮 lane4b 报告（集成测试 + 全 diff 复审 + camoufox UI）

> 任务书指定文件名 `r3-f02-lane3.md` 为 F02 R3 历史归档，`r3-f03-lane4.md` 已被同轮他路占用；按既有 `lane3b` 惯例落本名。

审查对象：4b26d7a23f..HEAD（7 commit：7b10716231 F03 feat → e1e996283c → 2f5a57b0d3 → 0a3e5fdab4 → c7a242cdf3 → 6cc43e0b81，含 F02 存量 diff 一并过目）。
测试账号前缀 `f02r3d-l4*`，base `pj6t7b1282tmwbt`（f02r3d-lane4，表 T1Add/T2Del/T3Vis），脚本存 `.work/ee-ce/lane4-tmp/f03test.py`。

## 结论

**issues：1 项 error 级（UI SPECIFIC_USERS 死路径）+ 3 minor + 2 E3/上游**。核心安全面（ADD/DELETE 拦截、VISIBILITY 遮蔽、校验对称、fail-open、owner 直通、public form）全部实测通过；未发现权限绕过。

## Issues

### E1（error，建议修）：表权限弹窗从默认态无法选择 Specific users
- 文件：`packages/nc-gui/components/dlg/Table/Permissions.vue`（template 单选行 `v-if="opt.value !== SPECIFIC_USERS || states[permission]?.option === SPECIFIC_USERS"`）
- 问题：`addDeleteOptions`/`visibilityOptions` 含 SPECIFIC_USERS，但单选行被 v-if 隐藏，仅当 grant 已经是 user 型时才显示 → 从默认态（Editors & up / Everyone）永远无法经 UI 配置 user 型 grant；`buildPayload` SPECIFIC_USERS 分支、users 多选、`loadCurrent` user 映射全部成为不可达代码（预设 grant 后可回显可编辑，实测确认）。
- 实测：默认态弹窗截图仅 3 选项（Creators/Editors/Nobody，`lane4-tmp/dlg-open.png`）；API 预置 user-grant 后重开弹窗显示 Specific users + 用户 chip + Reset 按钮（`lane4-tmp/dlg-usergrant.png`）。API 面 user-grant 全通（B6/B6a/B6b/C2/C2a/D10）。
- 建议：去掉该 v-if（照 Field/Permissions.vue 直接渲染全部选项），或选中即显示。

### M1（minor）：enforce_for_form 开关未暴露
- `KeyState.enforceForForm` 读取后未渲染未提交；API PATCH `enforce_for_form:false` 实测生效（public form F4/F5）。调研 §6.9「弹窗需暴露」未做，记 fork 限制（默认 true 偏保守方向）。

### M2（minor）：弹窗多 key 保存无回滚
- `save()` 循环三个 key，中途失败仅 toast，已提交 key 不回滚。记观察。

### M3（minor）：切到 Specific users 未选人时点 Save 会删既有 grant
- `buildPayload` 返回 undefined → 走 `!payload` 分支删 grant。「清空=回默认」语义勉强自洽，易误触，记观察。

## 集成测试（API 实测，71 查按修正后预期全过）

脚本 `f03test.py`：65 项 + public form 6 项。两处"FAIL"均为测试预期/上游问题，非 F03：
- B1g upsert 纯 update 500：**上游 CE 既有 bug**（`BaseModelSqlv2.ts:6065` afterUpdate `Cannot read properties of undefined (reading 'Id')`，零 grant 同样复现，fork diff 未触碰该区域）。F03 ADD hook 位置正确（toInsert 拆分后、`toInsert.length` 才查），mixed 批 insert 被 403（B1h）已证明 toInsert 覆盖。
- D9 editor 在 role:viewer VISIBILITY grant 下可见 T3：SDK 语义「该角色及以上」（editor≥viewer），原测试预期写反，行为正确。

通过项（摘）：
- **ADD**：nobody 拒 editor/creator、owner 直通；bulk/v1 单条/v1 bulk 全 403；user-grant 精确匹配（edA 过 edB 拒）；role creator 过 editor 拒；删 grant 恢复；per-entity fail-open（T1 有 grant 时 T2 无 grant editor 照插 200）。
- **DELETE**：v2 bulkDelete / v1 delByPk / bulkDeleteAll 三路全拦；nobody 拒 creator；user-grant edB 过 edA 拒；delete-all user-grant 放行。
- **VISIBILITY**：nobody → editor 表列表消失、meta 404、v2 data 404、v1 data 404、v1 insert 404、owner 全通；role:viewer → viewer 可见 editor 隐藏；user → edB 可见 edA 隐藏；删 grant=Everyone 往返。
- **校验对称**：重复 grant 400、below-min role 400（ADD+DELETE 双 key）、null/空 role 400、nobody+subjects create/PATCH 双拒、user 空 subjects 拒、未知/跨 base 表 400、field key 配 table 400、未知 granted_type 400、GET 未知 permission id 404。
- **ACL**：permissionList editor+（viewer 403）、CRUD creator+（editor 403、owner 200）。
- **public form**：无 grant 匿名 200；nobody(enforce_for_form=true) 403 文案 `You don't have permission to create records in T2Del`；PATCH enforce=false 匿名 200。isPublicForm flag 仅 public-datas 打（datas.service:1213 有意不打，注释明确）。
- **F02 回归**：field grant nobody → editor PATCH 403、owner 200。
- **F05-F10 回归**：variables/snapshots/dashboards/base(is_private)/table meta 全 200。
- **工具链**：`npx tsc --noEmit` exit 0；jest `2 suites / 26 tests` 全过（uniqueConstraintHelpers + baseVariableValidators Fork 桶）。

## 代码复审（全 diff，30 文件 +2275/-77）

- `Permission.ts`：list 刻意无缓存（注释说明 NocoCache 键空间坑）、update grant-shape 对称（R2-R5 修复在位：显式 null role、nobody+subjects、nobody→role 必带 role、user 必须有 subjects、nobody 落库清 subjects/role）、`deleteByBaseId` 挂 Base 软删+硬删。
- `checkPermission`：owner 直通（getProjectRole）、multi-grant any-deny、匿名 form 上下文 enforce_for_form、per-permission 文案（TABLE 走 title 免查 columns）、req.context 请求级 permissions 复用、extract-ids 预置空数组不短路（回源 list）。
- 挂点完整性：insert.ts single+bulk（bulk 尊重 `skipPermissionCheck`，仅 import/copy 通道传 true——controller 不透传用户参数，无 bypass）、nestedInsert（isFormContext）、bulkUpsert 拆分后 toInsert、delByPk/bulkDelete/bulkDeleteAll（bulkDeleteAll cookie=req 链路核过，user 可达）。
- `extract-ids`：主路径设 `ncTableId`（c7a242cdf3）+ tableName fallback + AclMiddleware VISIBILITY gate（空权限短路、isServiceUser 豁免、404 not 403）；data-table.service.ts:398 失实注释已修。
- 6cc43e0b81 清理彻底：`git ls-files` 无 `.v1a/.reasonix` 残留。
- 前端：Node.vue/View.vue/Details.vue/ColumnMenu.vue gate 全部 flag 化（`blockTableAndFieldPermissions=false`），`useExpandedFormStore` 去 isEeUI 短路，legacy `grid/Table.vue` 补 TABLE_RECORD_ADD，usePermissions 与后端共享 `evaluateTableFieldPermission` 决策（单 grant 不变量由 create 重复检查保证，`grants[0]` 取法成立），useViewData 惰性 getter 修冻结，i18n en/zh 双语键齐全。

## UI 段（camoufox-cli；MCP 拒 localhost 回落本机 CLI）

- 菜单：T1Add 节点 context 菜单含 "Edit table permissions"（gate 已解，无 upgrade 弹窗）。
- 弹窗：三 key 默认值正确（Editors & up ×2 / Everyone），NcModal 正常渲染（见 E1 SPECIFIC_USERS 缺陷）。
- UI 写路径：选 Nobody→Save→API 侧 grant 由 user 型 PATCH 为 nobody（subjects 清空，R3 不变量生效）；预设 grant 后 Reset table permissions 按钮在位。
- 截图：`lane4-tmp/dlg-open.png`、`lane4-tmp/dlg-usergrant.png`。
- **E3（环境）**：本机 camoufox daemon 单 tab 被并行 lane 共用（实测被切到 L2R3-F03 base、会话被互踢登出，avatar=L2），editor 身份的树过滤/加行按钮禁用两项无法做确定性 UI 验证；该两面为服务端过滤（D2/D4 已 API 证实）+ 前端 `isAddingEmptyRowAllowed`/`usePermissions` 接线（代码审过），风险低。有诊断证据，按 TASK 记 E3 不打断计数。

## 备注

- 测试数据未清理（base `pj6t7b1282tmwbt`、表 T1Add/T2Del/T3Vis、grant 已清空、账号 f02r3d-l4*@lanetest.local），供 orchestrator 复核；需清理可整 base 删。
- service user/自动化对 grant 无豁免（调研 §5 建议放行未采纳）＝与 enforce_for_automation 默认 true 语义一致，记 fork 语义；synced table 拒配为代码路径审查（无 synced 表可造）。
