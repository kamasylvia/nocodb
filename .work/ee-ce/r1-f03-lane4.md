# r1-f03-lane4 — F03 Data permissions 复审 R1（集成测试 + 全 diff 复审 + UI 段）

> lane4（同规格编制，独立隔离）。审查对象：commit 7b10716231（F03 主提交）+ e1e996283c（VISIBILITY 默认 Everyone 修复）。测试环境：dev :8080/:3000，DB nocodb-dev，测试 base `l4f03_base2`（pk4eyjy2j09lvk3），账号 l4f03-owner/editor/creator@ce-ee.local（现场保留供裁决复现）。

## 结论

**issues（2 error）：**

1. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1357-1378（F03 VISIBILITY 检查块位置）:TABLE_VISIBILITY 遮蔽只存在于 legacyExtractIds 分支，带 :baseId/:baseName param 的路由（全部 /api/v1/db/data/... 系列）走 use() 主分支（~140-480 行），不设置 req.context.ncTableId 也不跑该检查 → 隐藏表对 base 成员经 v1 API 完全可读可写:建议把 VISIBILITY 检查挪到两分支共汇点（additionalValidation 或 use() 尾部统一按 ncTableId 判），或在主分支解析 tableId/tableName 后设置 ncTableId 并复用同一检查`

2. `packages/nc-gui/components/dlg/Table/Permissions.vue:332-386（选项按钮区）:Configure 弹窗三 section 的全部选项按钮渲染为空注释节点（DOM: <div class="flex items-center gap-2"><!----></div>），innerText 无任何选项文本（Editors & up/Creators & up/Specific users/Nobody 均缺失），用户无法配置任何 key，Save 因 states 空、dirty 恒 false 实际 no-op:同页 F02 dlg/Field/Permissions.vue 用普通 div+GeneralIcon 渲染选项正常（同 SDK PermissionOptions 数据源），建议照 F02 模式重写选项渲染或排查 NcButton 在 <template v-for> 内渲染为空的原因`

**非 error 观察（供裁决裁定归属）：**

- O1. e1e996283c 误提交 `.reasonix/tasks/*` 会话工件 9 组（events.jsonl/snapshot.json/task.lock）进 git — repo 卫生，建议 `git rm -r --cached .reasonix` + .gitignore。
- O2. `DlgTablePermissions.vue:35` KeyState.enforceForForm 死字段（loadCurrent 读、buildPayload 不写、UI 无开关）——enforce_for_form 恒默认 true 不可配。属 research §7.9 建议暴露的开关，若裁剪应删字段并记 fork 限制。
- O3. checkPermission 无 service-user（AUTOMATION/WORKFLOW/SYNC）豁免——grant 存在时自动化写入被拦。research §5 建议 v1 放行未实施；从严方向，建议记 fork 限制。
- O4. 前端 usePermissions.isAllowed 取 grants[0]，后端 checkPermission 是 any-deny——multi-grant 语义前后端不一致；API 层 duplicate 防护下多 grant 不可达，观察级。

**上游遗留（非 F03 diff 引入，勿计 fork error）：**

- U1. v1 别名 title 路由 404（"Table 'Alpha' not found"）：extract-ids 主分支 `Model.get` 仅按 id 匹配（上游 c1d409a82b，2026-01-10）。用表 id 路径测试不受影响。
- U2. PK-based bulkUpsert 纯 update 单行批写后 500：`BaseModelSqlv2.ts:4205` `afterUpdate(existingRecords[0],...)` 而 existingRecords 仅 merge-mode 分支回填（PK-based 分支保持 []）（上游 5c6b198206 "feat: row expansion"）。实测 UPDATE 本身成功落库（probe-upd2），500 在 after-hook；F03 的 ADD hook 在拆分后检查，正确未拦该批。

---

## 集成测试结果（API 实测，nocodb-dev）

### 矩阵 A/B：ADD/DELETE × 角色 × 路径（24 断言全过）

| 断言 | 结果 |
|---|---|
| A0 无 grant editor insert fail-open 200 | PASS |
| A1 nobody：editor/creator insert 403，owner 200 | PASS×3 |
| A6 nobody bulk insert（v2 数组）403 | PASS |
| A7 nobody v1 单插（single path）403 | PASS |
| A8a-write nobody ADD 下纯 update 批（upsert）**写入成功**（hook 拆分后检查，不误伤） | PASS |
| A8b/A8c upsert 混合批（含新行）403 | PASS×2 |
| A9 editor update（PATCH 非 upsert）不受 ADD 拦 200 | PASS |
| A2 role:creator：editor 403 / creator 200 | PASS×2 |
| A3 role:editor：editor 200 | PASS |
| A4 user:[editor]：editor 200 / creator 403 / owner 200 | PASS×3 |
| A5 删 grant 后 fail-open 恢复 200 | PASS |
| B1 nobody DELETE：v2 单删/批删 403、deleteAll（id 路径）403、v1 delByPk 403 | PASS×4 |
| B2 nobody：creator 403 / owner 200 | PASS×2 |
| B3 删 grant 恢复；B4 role:creator editor 403 / creator 200 | PASS×3 |

### VISIBILITY（Beta 表 nobody/role/user grants，22 断言）

| 断言 | 结果 |
|---|---|
| v2：meta 404 / data GET/POST/PATCH/DELETE 404 / count 404 / 表列表消失（editor+creator） | PASS×8 |
| owner 全链直通（列表含 + data 200） | PASS×2 |
| 删 grant 后 fail-open 200 | PASS |
| role:editor：editor 200、creator 可见；role:viewer：editor 200 | PASS×3 |
| user:[editor]：editor 200 / creator 404 | PASS×2 |
| **v1 data 路由（GET list/GET row/PATCH/POST）editor 全通（200，数据泄露+写入落库）** | **FAIL → error#1** |
| bulk alias GET 无此路由 404（非遮蔽语义） | 记录 |

### 校验对称（D 系列，15 断言全过）

POST：FIELD key 于 table 400 / 未知 key 400 / nobody+subjects 400 / 伪造 granted_role 400 / role:viewer 低于 ADD、DELETE minimumRole 400×2 / user grant 无 subjects 400 / 伪造 entity_id 400 / duplicate (entity,entity_id,permission) 400（POST2 400 实证）。
PATCH：nobody+subjects 400 / 伪造 role 400 / nobody→role:viewer（VISIBILITY 合法）200 / ADD role:creator→viewer 400（minimumRole）/ PATCH permission key 被白名单忽略（key 不变）。
ACL：editor create 403 / editor list 200 / PATCH/DELETE 属主校验（cross-base 走 base_id 检查）。

### 回归（9 断言全过）

F05 变量 create/list 200（key 需 UPPER_SNAKE）；F07 snapshot list 200；F10 dashboards 端点可达；F02：Secret nobody grant 下 editor PATCH Secret 403 / PATCH Name 200 / insert 含 Secret 值 403 / insert 不含 200；F08 base list 200。

### 静态

- `npx tsc --noEmit` exit 0（packages/nocodb）。
- jest 26/26（2 suites：uniqueConstraintHelpers.Fork / baseVariableValidators.Fork）。

---

## 代码复审（git 4b26d7a23f^..HEAD 全 diff，F02 触碰面 + F03）

- ADD 4 钩：insert.ts single(:77)/bulk(:362,正确包在 `!skipPermissionCheck` 内)、nestedInsert(:3079, isFormContext=!!request.isPublicForm)、bulkUpsert(:3867, **在 toInsert/toUpdate 拆分后仅查 toInsert.length**，A8 实证不误伤纯 update 批)。✔
- DELETE 3 钩：delByPk(:2251)/bulkDelete(:4977)/bulkDeleteAll 包装层(:5546)。trash 永久清/F07 快照删不经这些公有方法，无 skip 通道需求成立。✔
- checkPermission：owner 直通、fail-open（permissions 空 return）、multi-grant any-deny（break on first deny）、匿名走 isFormContext+enforce_for_form、TABLE label 短路径（不查 columns）、per-permission 文案。`reqContext = req.context ?? this.context` 修了实例缓存污染。✔
- fieldPermissionEntityIds：Set 去重、system/pk/FK/system-col 过滤、title+column_name+id 三键。✔
- permissions.service：TABLE 三 key 白名单 + Model 存在/base 归属/synced 拒；update 走 extractProps 白名单（entity/entity_id/permission 不可 PATCH 越权改，实测 key 不变）；validateGrantShape 共享（enum/minimumRole/nobody+subjects/subjects 形状），create/update 对称。✔
- extract-ids VISIBILITY：空 grant 短路（permissions.length &&）、service user 豁免、匿名由 helper 回落 default visibility、404 遮蔽语义——但**只在 legacyExtractIds 分支生效**→ error#1。
- Permission.list：刻意无 NocoCache（R1 注释），写回 context.permissions；中间件先 list 再传入，匿名分支 context.permissions 一致性成立。
- 探针/console.log 残留：0（全 diff `+` 行 grep console. 零命中）。错误消息无内部泄漏（表 title/id 级）。
- 前端：Node.vue gate flag 化 ✔、useExpandedFormStore 去 isEeUI ✔、legacy grid Table.vue isAddingEmptyRowAllowed 补 ADD ✔（computed 内调 usePermissions() 非 setup 上下文——浏览器端实测可用，反模式观察）、Content.vue 摘要三行 + VISIBILITY 默认 Everyone（e1e996283c）✔、Table.vue `?? true` 尾随兜底无害。

---

## UI 段（camoufox-cli，截图存 .work/ee-ce/）

1. **owner**：登录 → Alpha grid → 表详情 Permissions tab → 三 key 摘要正确（Everyone/Everyone/Everyone，e1e996283c 修复生效）→ Configure 打开弹窗 ✔。
   - 截图：`.work/ee-ce/l4f03-owner-permissions-tab.png`（摘要）、`.work/ee-ce/l4f03-owner-permissions-dialog.png`（弹窗）。
   - **但弹窗选项按钮零渲染**（DOM `<div ...><!----></div>`，innerText 无选项文本）→ error#2。F02 字段弹窗同页对照选项正常（Creators & up/Editors & up/Specific users/Nobody 全渲染），排除 SDK 数据问题。
2. **editor**：Secret 列值遮蔽（全空，F02 生效）、Name 正常、New record 正常（无 ADD grant fail-open）；Details 内 **Permissions tab 对 editor 隐藏**（role gate 生效，owner 可见）。
   - 截图：`.work/ee-ce/l4f03-editor-grid.png`。
3. **console error / 5xx 双零**：editor 会话全程 fetch/XHR instrument（≥400 记录）+ window error/unhandledrejection hook → errs:[]、net:[]。✔

（附：`l4f03-base-home.png` 为 base home 布局存档。）

---

## 复现指引（error#1）

```
# 现场已保留：base pk4eyjy2j09lvk3 / Beta mxfusa93kguavvs / editor l4f03-editor@ce-ee.local
# 1. owner 建 Beta VISIBILITY nobody grant（POST /api/v2/meta/bases/pk4eyjy2j09lvk3/permissions）
# 2. editor token：
curl -s /api/v2/tables/mxfusa93kguavvs/records -H "xc-auth: $ET"        # 404 ✔
curl -s /api/v1/db/data/noco/pk4eyjy2j09lvk3/mxfusa93kguavvs -H "xc-auth: $ET"  # 200 ✗（数据泄露）
curl -X PATCH /api/v1/db/data/noco/pk4eyjy2j09lvk3/mxfusa93kguavvs/1 -d '{"Title":"x"}'  # 200 ✗（写入）
```

## 证据档案

- 全部 API 断言输出在上文表格（原始脚本 /tmp/l4f03/matrix*.sh，会话临时目录）。
- DB 现场查询：nc_permissions（base_id=pk4eyjy2j09lvk3）行与 API 行为一致（psql nocodb-dev 只读核对）。
- bulkUpsert 500 栈：`afterUpdate (...BaseModelSqlv2.ts:6065) TypeError: Cannot read properties of undefined (reading 'Id')`，blame 5c6b198206（上游）。
