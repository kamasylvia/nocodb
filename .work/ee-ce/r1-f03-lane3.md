# r1-f03-lane3 — F03 Data Permissions R1 轮 lane3(同规格编制)报告

审查对象:commit 7b10716231(+e1e996283c);代码面含 F02 触碰面回归(4b26d7a23f^..HEAD)。
环境:nocodb-dev @ qnap.elf-balance.ts.net:5432(**仅 nocodb-dev**);后端 :8080(未重启);前端 :3000(nuxt dev,camoufox-cli UI 段)。
测试账号:lane3-f03-owner(super)/editor/creator;base=p2ul0ca5fiabj7k(lane3-f03-ws),T1=mb4vsed1o9c9ufz(对照)、T2=mofweau38l09d8k(目标);grant 全程 API 写入,测试结束已清零并终验 fail-open。

## 结论

issues:

1. `packages/nc-gui/components/dlg/Table/Permissions.vue:339-342(选项行 NcButton,经 template v-for + v-if)`:**弹窗三个 section 的全部选项行 NcButton 静默渲染为空注释(`<!---->`),0 个可配置选项,弹窗不可用**(UI 实测)。建议:照 F02 `dlg/Field/Permissions.vue:229-247` 的纯 div option 行(v-for div + @click,无 NcButton/无 template-v-for+slot 结构)重写选项行;并查运行时组件渲染静默失败的根因(编译产物、SDK 模块均已验证正常,见证据 §UI)。
2. `packages/nc-gui/components/dlg/Table/Permissions.vue:151,185,224(save 对 undefined payload 的判定)`:SPECIFIC_USERS 未选任何用户时 `buildPayload` 返回 `undefined`,save 只判 `payload === 'DELETE' || payload === null`,`undefined` 穿透 → 对 grantId 存在/不存在分别发 PATCH/POST 空 body → 后端 400 错误 toast(意图是静默跳过)。建议:`if (!payload || payload === 'DELETE')`。
3. `packages/nocodb/src/models/Permission.ts(validateGrantShape/update 的 nobody 守卫)`:对 nobody grant PATCH `{granted_role:"bogus_role"}`(不带 granted_type)→ 200,`granted_role='bogus_role'` 落库(枚举/minimumRole 校验仅在 resolved type=role 时执行;nobody+granted_role 组合 create/update 均不拒,与 nobody+subjects 的对称拒不一致)。实测:PATCH 200 落库;判定不受影响(SDK evaluatePermission 对 NOBODY 恒 deny 除 owner),属脏数据/数据卫生面,低危。建议:resolved targetType=NOBODY 时对 granted_role 清 null 或显式拒;create 端 validateGrantShape 同步拒 nobody+granted_role。

无 E3 项(前端 dev server 为他人会话进程,遵守不重启约束,UI 段在现有 :3000 dev server 上完成,不影响判定)。

## 逐项结果(集成测试,全量)

### 1. ADD 全矩阵 — 全 PASS
| 场景 | 结果 |
|---|---|
| nobody × editor v2 单条/批量 insert T2 | 403 / 403(PASS)|
| nobody × creator insert | 403(PASS)|
| nobody × owner insert | 200(PASS,owner 直通)|
| role:creator × editor → 403;× creator → 200(单+批量)| PASS |
| role:editor × editor → 200;× creator → 200 | PASS |
| nobody 时 editor 对 T2 的 update/delete(非 ADD 路径)| 不受 ADD 拦(PASS,手动复核 200/200;脚本首轮两条 FAIL 为测试脚本嵌套引号假阳)|
| v1 data insert(datas.service→nestedInsert)× editor | nobody 403(消息 "You don't have permission to create records in Lane3T2");删 grant 后 200(PASS)|
| v3 upsert 拆分语义(`/api/v3/data/:base/:model/records/upsert`,fieldsToMergeOn)| 纯 update 批 + ADD nobody → 200;混合批(含新行)→ 403(消息 "…create records in Lane3T2");删 grant 后 insert 批 → 200(PASS,验证拆分后只对 toInsert 查 ADD)|

### 2. DELETE 全矩阵 — 全 PASS
- nobody × editor:v2 单删 403、v2 批删 403、v1 delByPk(datas.service/old-datas 路径)403、deleteAll(v1 bulk/all)403 — 消息 "…delete records in Lane3T2";creator 单删 403;owner 单删 200(PASS)
- PATCH 切 role:creator:editor 403 / creator 200;PATCH 切 role:editor:editor 200(v1 delByPk creator 200、deleteAll editor 200)(PASS)

### 3. VISIBILITY + 遮蔽 — 全 PASS
- nobody:editor/creator GET meta T2 → **404**;GET data T2 → **404**;owner meta/data → 200(PASS)
- 表列表 `/api/v2/meta/bases/:baseId/tables`:editor/creator 列表仅剩 Lane3T1(hasT2=0);owner 含 Lane3T2(hasT2=1)(PASS)
- 匿名 GET data → 401(非 500;Extract-ids F03 块对匿名走 helper default-visibility 回落,未带 share ctx 前被认证层拦)(PASS)
- role:viewer(editor/creator 可见 200);role:creator(editor meta 404 / creator data 200)(PASS)
- link 折叠:T1→T2 Links 列,T2 对 editor 隐藏时 links 子资源(`/tables/T1/links/:col/records/:rowId`)返回折叠形态 {Id, Name}(pk+pv;该测试表仅此二列,折叠=全列故与 owner 视角同形,折叠语义生效)(PASS)
- fail-open:删 VISIBILITY grant → editor meta 恢复 200(PASS)

### 4. fail-open 全路径 — PASS
- 零 grant 时 editor/creator 对 T1/T2 insert/delete/update/meta/data 全 200(§A 4 项 + 各矩阵删 grant 后复核);ADD/DELETE/VISIBILITY 三 key 删 grant 后下一请求即放行(PASS)

### 5. 校验对称 — PASS(除 issue 3)
create 全 400:nobody+subjects;role 缺 granted_role;user 缺 subjects;granted_type=bogus;permission 非法枚举;FIELD key 配 table;entity_id 表不存在;role:viewer 低于 ADD/DELETE minimumRole(editor)。
update:PATCH nobody+subjects → 400;PATCH 显式 null granted_role 于 role grant → 400;PATCH role:viewer 于 VISIBILITY(合法)→ 200。
ACL:editor create grant → 403;editor list → 200;creator create → 200。
重键:同 (entity,entity_id,permission) 二次 create → 400 "already exists"(PASS)。
注:测试脚本 2 条"FAIL"为脚本自身笔误(枚举 camelCase/期望值参数错位),非产品行为。

### 6. 回归 — PASS
- F05 variables list 200;F07 snapshots list 200;F10 dashboards list 200;F08 bases list 200
- F02 字段权限:Name 列 nobody grant → editor PATCH Name 403("You don't have permission to edit the field Name");删 grant → 200(注:首轮误选 system 列 nc_created_by 被 fieldPermissionEntityIds 过滤放行 = 预期行为)
- 后端 `npx tsc --noEmit` → 0 错误;jest 全桶(Fork/Integration/Source)26/26 PASS
- console/探针:`git diff a4e4e2f68f..HEAD` 与全 F02 触碰面 `console.*` = 0;无 debugger/探针残留

## 代码复审(整个 diff)

- `fieldPermissionEntityIds`(BaseModelSqlv2.ts:10581):Set 去重、三键匹配(column_name/title/id)、system/pk/FK/uidt 过滤全对;R6 全收集防 decoy 劫持 ✓。实测佐证:system 列 payload 被放行。
- `checkPermission`(:10620):multi-grant any-deny(break 于首个 deny,顺序无关)、owner 直通、无 grant fail-open、req.context 承载 per-request 清单、form 上下文 enforce_for_form 豁免、TABLE label 分支 + per-permission 文案(permissionDeniedMessage)✓;错误消息不泄漏(仅表名/列名)✓。
- `Permission.update` 三守卫顺序:validateGrantShape → granted_type 合法性 → nobody+subjects 拒 → role 空角色拒(explicit-null 语义 R4)→ user 无 subjects 拒,全部先验后写;nobody 切换清 granted_role + subjects 重建后再清 ✓。entity_id/entity/permission 不可经 PATCH 改(extractProps 白名单)✓。**遗留缺口即 issue 3**。
- `validateGrantShape`:enum/minimumRole(SDK PermissionMeta)/subjects 形状/nobody+subjects ✓;shared by create+update ✓。
- extract-ids 中间件(:1360-1377):`ncTableId && ncBaseId && !isServiceUser` 豁免、`permissions.length` 空短路、404 遮蔽(与 UI-ACL 同语义)、匿名回落 helper 内 default visibility ✓;data-table.service.ts:398 失实注释已改 ✓。
- permissions.service:TABLE 三 key 白名单 + Model 存在 + base 归属 + synced 拒配 ✓;create 前 dup 检查 ✓。注意 FIELD 分支无跨 base 列归属校验(F02 面;写进他 base 列 id 的 grant 为 inert 行,不越权;单路观察,建议后续对齐 TABLE 分支加 table.base_id 校验)。
- insert.ts:single/bulk 双 ADD 钩;bulk 包在 `!skipPermissionCheck` 内(import/copy/snapshot 免检通道沿用)✓;bulkUpsert 钩在拆分后仅 toInsert(实测 §1 末行)✓;delByPk/bulkDelete/bulkDeleteAll 三 DELETE 钩 cookie 传递链完整(datas.service:231/1275、old-datas:153 均 param.cookie;bulk-data-alias 反射入口经包装层 cookie)✓。
- 前端:useExpandedFormStore 去 `!isEeUI` 短路 ✓;Node.vue gate flag 化(blockTableAndFieldPermissions,CE 沙箱 stub 恒 null 与 gate 组合正确)✓;DlgTablePermissions v-if 解 isEeUI ✓;usePermissions VISIBILITY 默认 EVERYONE ✓(e1e996283c);Content.vue 三行摘要 + 编辑入口 ✓;legacy grid Table.vue isAddingEmptyRowAllowed 补 ADD(?? true 兜底)✓;en/zh-Hans key 补齐 ✓。

## UI 段(camoufox-cli,:3000 dev)

- owner 登录 → base 树 Lane3T1 右键菜单含 **"Edit table permissions"**(gate 解除实证)→ 打开弹窗:三 section(Who can add/delete records、Table Visibility)+ Cancel/Save 渲染,`data-testid=nc-table-permission-{TABLE_RECORD_ADD,TABLE_RECORD_DELETE,TABLE_VISIBILITY,save}` 就位。
- **但选项行(NcButton radio)全部不渲染**(issue 1):section innerHTML 仅 263 字符、buttons:0 spans:0,3 个空 div 各含 `<!---->`;截图 /tmp/lane3-dialog.png。已排除:SDK 模块(浏览器 fetch 源服务版含全 7 值)、编译产物(v-if 正确编译至 div,`_component_NcButton = import nc/Button.vue`)、console error/warn(hook 后重开弹窗零输出,静默)。footer Cancel/Save 同组件正常渲染。
- editor 视角(间接,API 层):ACL 403 已验;树菜单 editor 侧因时间未单独走 UI。

## 观察(非 error,不入计数)

- 每写请求 Permission.list 全量查询 3 次(extract-ids + FIELD 钩 + TABLE 钩;list 无缓存为 F02 R1 显式裁定 + subjects N+1)——backlog 延续,F03 未放大单点语义。
- 前端 isAllowed 仅取 grants[0] vs 后端 any-deny:(entity,entity_id,permission) 唯一约束下等价;脏双 grant 时可能分叉(F02 遗留,无现成复现路径)。
- KeyState.enforceForForm 为死字段;enforce_for_form 无 UI 开关(research §6.9 建议暴露;fork 沿默认 enforce=true,记 fork 限制)。
- FIELD create 无跨 base 列归属校验(F02 面,inert 脏行,建议对齐 TABLE 分支)。

## 证据索引

- 测试脚本/凭据运行时拉取:.work/ee-ce/lane3-{env,setup,run1,run2b,run3}.sh、lane3-lib.sh、lane3-ids.env(凭证不入库;grants 已清零,base 留存 nocodb-dev)
- UI 截图:/tmp/lane3-dialog.png(弹窗无选项态)
- 关键响应体:403 文案两条(create records / delete records in Lane3T2)、404 tableNotFound、400 校验消息均在上述各节
- tsc exit 0;jest 26/26(输出日志 exec_932f…/call_1babc… 与 exec_3a3d…/call_4fd0ec… stdout)
