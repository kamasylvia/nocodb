# r2-f03-lane4 — F03 Data permissions R2 收敛轮（lane4）

> 独立 lane：功能全量集成测试 + 整个 diff（4b26d7a23f^..HEAD，27 文件 +2256/-71）代码复审 + camoufox UI 段。
> 环境：:8080 dev（含 R1 修复 dist 23:56 构建）/ :3000 / nocodb-dev（base `lane4-r2-base` pao80acdkkrf6l0，测试账号 l4f03-{owner,editor,creator}@t.local）。
> 产物：.work/ee-ce/lane4/{setup,int1,int2,int3,int4}.py、int1.json；截图见文末。

## 结论

**issues 列表（非 PASS）**

1. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1107-1113`（对照 `:487` else 分支、`:211-218` tableId else-if）：**v1 data-alias 路由族 TABLE_VISIBILITY bypass 未修复，R1 catch-all 加错方法** — `req.context.ncTableId` 唯一赋值点全在 `legacyExtractIds`（:1100/:1113），该方法仅当路由**不含** `:baseId/:baseName` 时经 `:487` else 调用；v1 路由族 `/api/v1/db/data/:orgs/:baseName/:tableName` 带 `:baseName` → 走 `use()` 主分支（:131-495），:169 把 `params.tableName` 并入 tableId 解析后**只设 `req.ncSourceId`（:215）从不设 ncTableId** → AclMiddleware VISIBILITY gate（:1378 `req.context?.ncTableId &&`）永跳 → bypass 保持。建议：use() 主分支 tableId else-if 内设 tableIdToCheck 并写入 req.context（或 catch-all 等价逻辑移至该分支 req.context 构建后）；修后 v1 全动词回归 404
2. `packages/nc-gui/composables/usePermissions.ts:139-145`：**Permissions tab 摘要 ADD/DELETE 无 grant 显示 "Everyone"（应 "Default — Editors & up"）** — `getPermissionSummary` 用 `entity===TABLE ? EVERYONE : EDITORS_AND_UP`，e1e996283c 意图仅 TABLE_VISIBILITY→EVERYONE，却把 ADD/DELETE 一并覆盖；与配置弹窗默认（loadCurrent：ADD/DELETE=EDITORS_AND_UP）自相矛盾（截图 summary-bug）。建议：判断键改 `permission===PermissionKey.TABLE_VISIBILITY`
3. `packages/nc-gui/composables/usePermissions.ts:53-77`：**grants 懒加载在 canvas 主视图从不触发（gate 提示层失效，后端兜底）** — 主视图任何路径（首载/重载/表切换）均不发 GET /permissions（PerformanceObserver buffered 多次复测 NONE）→ useState 空 → isAllowed 恒 true → ADD nobody 下 "+ New record" 按钮仍显示可点（点击后端 403，toast 文案正确）、FIELD nobody 下 Secret 列头 lock 不显示（截图 editor）。疑点：loadPermissions 内 `useNuxtApp()` 于 watch 回调/非 setup 上下文抛错被 catch 静默（loadedFor 置 null）；弹窗/Content.vue 的显式调用路径正常。无数据泄露（后端全动词拦截实测全对）。建议：composable setup 期捕获 $api 闭包或 tryUseNuxtApp 兜底；修后验证按钮隐藏+lock 显示
4. `packages/nocodb/src/models/Permission.ts:396-399`：**role→nobody PATCH 后 DB granted_role 残留** — R1 把 `updateObj.granted_role = null` 改 `delete`，payload 移键≠清列，实测 PATCH role:creator→nobody 后行内 granted_role='creator'。SDK nobody 分支忽略该列，功能无影响（editor/creator 均 403），数据卫生问题。建议：显式置 NULL
5. repo 卫生：`.v1a/.v1b/.v1c`（2f5a57b0d3 提交，body 却写 "remove stray PATCH/-X junk files"，与实际相反）+ `.reasonix/tasks/*` 18 个运行时产物（e1e996283c）。建议 git rm + .gitignore（`.v1*`、`.reasonix/`）

观察（非违反）：`hasTableVisibilityAccess` find-first vs checkPermission any-deny 不一致（dup 防护使用户不可达，纯防御深度）；`dlg/Table/Permissions.vue` enforceForForm dead state（UI 无开关，API PATCH enforce_for_form 实测生效）；save() 中 SPECIFIC_USERS 未选人 + existingId → 删 grant 回默认（可用但语义隐晦）；v1 单删不存在行 500（delByPk readRecord 无 null 检查）为上游遗留，非本 diff 引入（owner 无 grant 同样 500）。

## 逐项结果

### A. R1 修复验证
- ❌ v1 data 路由 nobody VISIBILITY → **bypass 保持**（issue 1；int2 E1：editor v1 list/read/count/insert 全 200，v2 对照 404）
- ✅ dup grant → 400（A4）
- ✅ entity=dashboard × TABLE key → 400（D3，R1 entity 校验）
- ✅ dialog getPermissionLabel + div 渲染：弹窗三 key/选项全渲染，VISIBILITY 默认 **Everyone**（e1e996283c 生效，截图 dialog）
- ✅ NOBODY 清 subjects/granted_role：payload 侧清（D18 证 DB 侧残留→issue 4，功能语义无损 E3）
- ✅ SPECIFIC_USERS undefined payload：不炸（API 建 user grant E2 精确：editor 200/creator 403）

### B. 全矩阵（int1 B 段 33 项）
- ✅ TABLE_RECORD_ADD × {nobody, role:editor, role:creator} × {editor, creator, owner} × {v2 insert, v1 insert, v2 bulk/array}：403/200 分界全对（owner 恒过）
- ✅ TABLE_RECORD_DELETE 同矩阵 × {v2 DELETE body, v1 DELETE}：全对（v2 单删=DELETE /records body Id，脚本首版路径错已纠）
- ✅ TABLE_VISIBILITY v2：nobody→editor/creator 404、owner 200；role:creator→editor 404/creator 200；meta 直连 404（B2）
- ✅ ADD 不 gate PATCH（nobody ADD 下 editor PATCH 200，B3）

### C. fail-open
- ✅ 无 grant editor insert 200；建 nobody → 403；DELETE grant → 立即 200（下一请求）

### D. 校验对称（全 400）
- ✅ create：field×TABLE key / table×FIELD key / dashboard entity / role 缺 granted_role / granted_role viewer 低于 minimumRole / 非法枚举 super / user 缺 subjects / nobody+subjects / 不存在 entity_id / 跨 base entity_id（D1-D10）
- ✅ update：PATCH viewer（低于 min）/ 非法枚举 / null role / nobody+subjects / user 缺 subjects → 400；PATCH role→editor、→nobody → 200；user grant PATCH team subject → 400（D11-D19）
- ✅ user grant 精确性（E2 复核，subjects=editor：editor 200 / creator 403）

### E. 公共表单（int4）
- ✅ nobody ADD（enforce_for_form 默认 true）→ 匿名 POST /api/v2/public/shared-view/:uuid/rows → 403
- ✅ PATCH enforce_for_form=false → 匿名 200；认证 editor 仍 403（豁免仅匿名）；删 grant → 匿名 200

### F. 回归
- ✅ F02：Secret FIELD nobody → editor PATCH Secret 403 / Name 200 / owner 200
- ✅ F05 变量 create+list；✅ F07 快照 create+list（异步副本生成）；✅ F10 dashboard list；✅ F08 editor bases 列表隔离（仅见受邀 base）
- ✅ tsc --noEmit 0；✅ jest（Fork 桶）26/26；✅ 探针/console.log/debugger 0 残留（diff 全量 grep）；✅ 错误消息不泄漏内部（表名级 label，无栈/SQL）

### G. UI 段（camoufox-cli，owner :3000）
- ✅ 右键 Notes → "Edit table permissions" 菜单可见（Node.vue gate 已解）→ 弹窗三 key + 选项正确渲染，默认 ADD/DELETE=Editors & up、VISIBILITY=Everyone（截图 1 r2-f03-lane4-dialog.png）
- ✅ Details → Permissions tab 渲染（三 key 摘要区 + Edit 入口 + Field permissions 两行），Edit 开弹窗正常（截图 2 同时取证 issue 2：ADD/DELETE 行误显 Everyone）
- ❌ editor：New record 按钮在 ADD nobody 下仍显示可点（后端 403 toast 正确）、Secret 列头无 lock（issue 3，截图 3 r2-f03-lane4-editor.png）
- ✅ console error 0 / 5xx 0（探针期；唯一 500 为 E4 人为触发的上游遗留路径）
- editor 无 Details Permissions tab = 预期（配置 creator+ 语义，F02 裁定）

### E3（外部限制，不计 error）
- dev server 间歇无响应（rspack 重建窗口），重试 15-60s 通过；v1 alias 路由表名 title 形式在本 dev 库不解析（上游 alias 行为，用 table id 形式完成验证）

## 证据索引
- 脚本/结果：`.work/ee-ce/lane4/{setup,int1,int2,int3,int4}.py`、`lane4/int1.json`（92 项判定，其中 26 FAIL 已逐一甄别：issue 1×3、脚本缺陷×22、E2 复核废案×1）
- 截图：`.work/ee-ce/r2-f03-lane4-dialog.png`（弹窗正常）、`r2-f03-lane4-summary-bug.png`（issue 2 现场）、`r2-f03-lane4-editor.png`（issue 3 现场）
- 测试基线：signup×3 + psql 提权 owner（nocodb-dev，凭证运行时经 Infisical KDL 拉取，库显式硬编码 nocodb-dev）
