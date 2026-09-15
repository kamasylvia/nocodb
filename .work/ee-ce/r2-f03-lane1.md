# r2-f03-lane1.md — F03 Data permissions R2 **收敛轮**（lane1：R1/R2 修复验证 + 全量集成测试 + 全 diff 终审）

> 审查对象：7b10716231（F03 主提交）+ e1e996283c / 2f5a57b0d3 / 0a3e5fdab4（R1 修复）+ **c7a242cdf3（R2 修复：ncTableId 主路径赋值）**。
> 方法：nocodb-dev API 全矩阵实测（独立 base `p3eb4cexc3czkpq` / table `mca2zofgqi8g52v`，owner psql 提权 super + editor/creator 邀请，权限行全部 API 写、multi-grant 场景 psql 插行）+ 4b26d7a23f^..HEAD 全 diff（27 文件 +2263/-71）代码复审。
> **与前版本文件的关系**：本文件此前的 R2 首轮 lane1 报告（07:54，base pt3c40yhbnvvwnl）判定 error-1「v1 VISIBILITY 修复补在死路」。该 error 已由 **c7a242cdf3** 修复（use() 主路径 `else if (tableId)` 分支补 `req.context.ncTableId = model.id`——恰为该报告建议修法）。本轮按收敛轮职责对修复后 HEAD 重新全量实测，error-1 **实证关闭**（见 §一）。

## 结论

**PASS**（0 error。2 minor + 5 观察 + 2 E3 存量，均无安全越权 / 功能回归 / fork 引入破坏。R1 全部 6 项 + R2 的 c7a242cdf3 全部实证有效；上轮 error-1 关闭。）

## 一、R2 修复验证（c7a242cdf3，本轮核心）

VISIBILITY nobody grant 下 editor 访问 v1 data 路由家族（`/api/v1/db/data/noco/:baseId/:tableId`）：

| 探针 | 期望 | 实测 |
|---|---|---|
| B4 GET list | 404 | **404 ✓** |
| B5 GET byId（有效行 id） | 404 | **404 ✓** |
| B6 POST | 404 | **404 ✓** |
| B7 PATCH | 404 | **404 ✓** |
| B8 DELETE | 404 | **404 ✓** |

grant 删除后同探针恢复 200（B14/B15）→ 非缓存伪影。owner 同路由全程 200（B10/B11）。c7a242cdf3 的 use() 主路径赋值 + 2f5a57b0d3 的 legacy fallback 双路均生效，v1/v2 data 路由 VISIBILITY 遮蔽统一。

## 二、R1 其余修复验证

- 重复 grant → 400（E3.1 实测）✓
- entity×permission 配对：table×RECORD_FIELD_EDIT 400、field×TABLE_RECORD_ADD 400、dashboard×TABLE_RECORD_ADD 400（E4/E3.3）✓
- NOBODY 清理：PATCH nobody 后 granted_role strip、subjects 删（E2.7/E2.8）✓（stale-role 残留例外见 minor-1）
- 弹窗 getPermissionLabel 导入（0a3e5fdab4）：dlg/Table/Permissions.vue:24 解构已在 ✓
- VISIBILITY 默认 Everyone（e1e996283c）：loadCurrent 无 grant → EVERYONE；getPermissionSummary TABLE 无 grant → EVERYONE ✓（代码确认）
- permissions.service 拒非 TABLE/FIELD entity（2f5a57b0d3）✓（E1/E3.3）

## 三、全矩阵（nocodb-dev 实测，~70 断言全过）

- **ADD**：nobody→editor/creator 403（v2 单条/v1 单条/v2 bulk/v1 bulk，C1.1-C1.4/C1.7）、owner 200（C1.8）；role:editor→editor+creator 200（C2）；role:creator→editor 403/creator 200（C3）。
- **DELETE**：nobody→editor 403（v2 单删/v1 删/v1 bulk 批删/v1 bulk delete-all，D1.1-D1.4）、owner 200（D1.7）；role:creator→editor 403/creator 200（D2）。
- **正交性**：ADD grant 下 update/delete 200（D1.5/D1.6）；DELETE grant 下 update/insert 200；v1 bulk PATCH-all 不受 ADD 拦（F3.1）。
- **bulkUpsert 拆分**：混合批在 ADD nobody 下 403（C4.2，检查在拆分后仅 gate toInsert）；纯 update 批语义被上游存量 500 遮蔽（E3-2）。
- **VISIBILITY**：v2 列表 404、meta tables 列表隐藏（grep 0）、直连 meta 404、creator 404（B1-B3/B9）。
- **multi-grant any-deny**：FIELD user(editor) + psql 注入 user(other) → editor 403，清理后 200（F1b.2/F1b.3，顺序无关）。
- **fail-open**：无 grant 全路径 200（A1-A9）；grant delete 后 v2+v1 立即放行（B13-B15/F1b.3）。
- **校验对称（全 400）**：invalid entity/permission/granted_type、跨 base 表、不存在表、role 缺 granted_role、bogus granted_role、viewer<minimumRole（ADD/DELETE）、user 缺 subjects、nobody+subjects、duplicate；VISIBILITY role:viewer 合法 200。update 侧对称全 400（E2.1-E2.6）+ nobody→user+subjects 200、subjects=[] 幂等 200（E2.9/E2.12）。
- **公共表单**（shared uuid 匿名）：ADD nobody 默认→403（G3）、enforce_for_form=false→200（G4）。
- **回归**：F05 variables create/list ✓（key 需 UPPER_SNAKE_CASE）、F07 snapshot create/list ✓ + editor snapshot ACL 403 ✓、F10 dashboard create ✓、F02 FIELD grant CRUD/any-deny/owner 直通全程覆盖 ✓；tsc 0 ✓；jest 26/26 ✓。F08 私有 base：F02/F03 diff 未触碰其文件，未做 API 抽测（注明）。

## 四、代码复审（全 diff）

- **fieldPermissionEntityIds**（BaseModelSqlv2.ts:10585）：✅ Set 去重、system/pk/ForeignKey/isSystemColumn 过滤、column_name/title/id 三键、R6 全收集（防 decoy 劫持）。
- **checkPermission**（:10613）：✅ owner 直通、请求级 reqContext、空列表 fail-open 短路、any-deny 顺序无关（F1b 实证）、匿名+isFormContext 尊重 enforce_for_form（fail-closed 方向）、per-permission 文案不泄漏。
- **update()**：✅ resolved-type 三守卫顺序、'granted_role' in data null 语义（R4）、subjects 重建+R3 nobody 兜底删。
- **validateGrantShape**：✅ 共享、enum/minimumRole/subjects 形状/nobody+subjects 对称。
- **挂点**：ADD=insert.ts single/bulk（`!skipPermissionCheck` 包裹，import/copy 免检）/nestedInsert（isFormContext）/bulkUpsert 拆分后；DELETE=delByPk/bulkDelete/bulkDeleteAll。link 系不加 DELETE 拦（对齐 EE）。与 research §7 裁定一致。
- **extract-ids gate**：✅ `ncTableId && ncBaseId && !isServiceUser` 前置 + `permissions.length` 空短路（零 grant 零开销）+ 404 遮蔽。
- **残留**：diff 内 console.*/debugger/TODO 新增 = 0；`.v1a/.v1b/.v1c` 曾随 2f5a57b0d3 误入（commit message 写 remove 实为 add），已在 6cc43e0b81 清除，HEAD 干净。

## 五、Issues（无 error）

**minor-1** `packages/nocodb/src/models/Permission.ts`（update() R5 注释处）：注释称 "reject bogus granted_role on NOBODY target" 实为静默 strip，且仅当 payload 显式含 granted_type=nobody 时生效——只 PATCH `{"granted_role":"bogus"}`（type 保持 nobody）时 bogus 落库持久（E2.5/E2.11 实证 stored granted_role='bogus'）。无安全影响（nobody 判定不读 granted_role；切 role 时被 enum/必填校验拒）。建议：validateGrantShape 对 NOBODY target 也校验 granted_role，或 update 后无条件清列。

**minor-2** `packages/nc-gui/components/dlg/Table/Permissions.vue`：(a) KeyState.enforceForForm 读而不写（死字段，弹窗无 enforce_for_form 开关，research §6.9 计划项被裁未记 fork 限制；默认 true 方向安全，G3 实证）；(b) save() 中 SPECIFIC_USERS 未选人时 buildPayload 返 undefined，`!payload` 分支会静默 DELETE 已有 grant（"解除限制"+成功 toast），与「保持现状」预期不符。建议：undefined 与 'DELETE' 分流；补 toggle 或记 fork 限制。

**obs-1** 前端 usePermissions.isAllowed/getPermissionSummary 只取 grants[0]，后端 any-deny 全量——由 create duplicate-400 保证单 grant，一致成立；未来放开多 grant 需同步。

**obs-2** hasTableVisibilityAccess（上游预埋 tableHelpers.ts:171）多 grant find-first vs checkPermission any-deny（F2.2 实证 psql 插第二 nobody 行后 editor 仍 200）；API 面被 duplicate-400 封死，仅 psql/脏数据可触发。另其 `!user` 分支读 context.permissions 而非入参 permissions（当前调用点先 list 写回 context，行为一致，潜在隐患）。

**obs-3** VISIBILITY nobody 下 shared form meta/提交仍 200（G5/G6）——shared 路由不经 gate，显式分享优先，与上游 shared-view 独立访问层一致；建议记 fork 语义说明。

**obs-4** grid/Table.vue:337 computed 内调用 usePermissions()（带懒加载副作用；loadedFor guard 防重复请求，开销小）。

**obs-5** Permission.list 1+N（subjects）查询/请求，extract-ids 高频面在多 grant base 放大（list 注释已声明 deliberately cache-free + backlog）；`permissions.length` 短路仅零 grant 生效。建议批量查 subjects（IN 一次）。

**E3-1（存量，非 fork 引入，有诊断）** 本 dev 环境公共表单 body→fields 映射失效：JSON/multipart 匿名提交均写全 NULL 行（DB 实证多行 Title/Amount NULL、created_by=usranonymous；`{"Amount":"notanumber"}` 不触发校验 = insertObject 恒空）。次生效应：F02 FIELD 表单 enforce（nestedInsert FIELD hook）因 entityId=[] 不可端到端实测。F02/F03 diff 对 public-datas.service 唯一改动为 +4 行 isPublicForm flag（e85a421d92），insertObject 构造为上游原版（git log -S 确认）——非 fork 回归。F03 自身表单强制（ADD，不依赖 payload）已 403/200 两态验证；isFormContext 分支共享逻辑经 G3/G4 证明工作。

**E3-2（上游存量）** v1 bulkUpsert 纯 update 批 500：`afterUpdate:6065 Cannot read properties of undefined (reading 'Id')`，owner 同 payload 同 500（与权限无关，函数未在 diff 触碰）。「纯 update 批不要求 ADD」由 C4.2（混合批 403）+ F3.1（bulk PATCH-all 200）两侧夹逼证明。

## 六、证据

- 测试脚本与原始输出：`.work/ee-ce/tmp-r2-lane1/`（phase_ab/b/cd/ce/c4f/f/f1b/g2/g1/h*.sh、probe_g.sh、probe_amount.sh）
- 账号：f03r2-{owner,editor,creator}@lane1.test；测试 base `p3eb4cexc3czkpq`（dev 库，权限行已清理，终态 fail-open 200 复核）
- commit diff 全文复读：7b10716231 / e1e996283c / 2f5a57b0d3 / 0a3e5fdab4 / c7a242cdf3 / 4b26d7a23f^..HEAD
- 环境：后端 dev :8080（未重启）；psql @ qnap.elf-balance.ts.net:5432/**nocodb-dev**（未触生产库）
