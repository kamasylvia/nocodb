# F03 Data permissions R3 lane5 — 终局收敛轮（全量集成测试 + 全 diff 复审）

**结论：PASS（无必修 error）**。7 项发现项（1 项语义缺口待裁决 + 4 minor + 1 E3 上游缺陷 + 1 UX 观察），逐项列后。

审查对象：7b10716231 + 2f5a57b0d3 + e1e996283c + 0a3e5fdab4 + c7a242cdf3 + 6cc43e0b81（git diff 4b26d7a23f..HEAD，21 文件 +1021/-201）。测试 base `pu51tgj44pwzb3k`（TableA `m2omeo2q12a0ovv` / TableB `mxdjxqe6y7pbxl9`），账号 owner/editor/creator/viewer 4 角色。

---

## 一、集成测试（全量，实测 nocodb-dev @ :8080）

### 1. 全矩阵拦截/放行分界 — 全对
- **ADD nobody**：editor/creator/viewer insert(v2 单/bulk) 403、v1 insert/bulk/upsert(mixed) 403；owner 200。update / delete / bulkUpsert 纯 update 批不受 ADD grant 影响（`bulkUpsert` hook 在 `toInsert.length` 守卫下，拆分后正确）。
- **DELETE nobody**：v2 bulkDelete 403、v1 delByPk 403、v1 bulk deleteAll(`/all?where=`) 403；owner 200；insert/update 不受影响。
- **role grants**：role:creator → editor 403 / creator 200 / owner 200；PATCH 改 role:editor 即时生效（editor 200 / viewer 403）。
- **user grants**：PATCH→SPECIFIC_USERS(editor) 后 editor 200、creator/viewer 403。
- **VISIBILITY nobody**：editor/creator meta 404、v2 data 404、v2 insert 404、count 404、aggregate 404、v1 data 404、v1 view-submit 404（R1+c7a242cdf3 v1 路径修复生效）；base meta 200、base 表列表中 TableA 消失；owner 全 200。
- **VISIBILITY role:viewer** → 协作者全可见（editor/creator/viewer 200）。**VISIBILITY user(editor)** → editor 200 / creator 404。删 grant → 下一请求恢复。

### 2. fail-open — 通过
无 grant 时 editor/creator insert/update/delete/bulk/viewer read 全 200；DELETE grant 删除后下一请求放行；VISIBILITY grant 删除后 creator 恢复 200。

### 3. 校验对称 — 全 400
- create（12 项）：非法 permission（TABLE_RECORD_EXPORT）、非法 entity（dashboard）、非法 granted_type（`haxx`，"Invalid granted_type haxx"）、role 缺 granted_role、granted_role 非法枚举、viewer 低于 minimumRole、user 缺 subjects、nobody+subjects、subject 非法 type、subject 缺 id、表不存在、cross-base 表 id（`mh8nffqz1b17ec3` 属 `pyibe0yitbp0cr8`）。
- update（7 项）：granted_type=haxx、nobody+subjects、role+granted_role:null、role+granted_role:''、role 非法枚举、user subjects:[]、低于 minRole — 全 400（R2/R4 三守卫对称）。
- ACL：permissionList editor 200 / viewer 403；permissionCreate/PATCH editor 403（creator+ only，acl.ts:559 生效）。

### 4. VISIBILITY 深层 — 通过
- link 折叠：TableB→TableA(hm link) + VISIBILITY nobody 下，editor nested-link 只返回 pk+pv（`{Id,Name}`），TableA 新增列 `Extra="SECRET-X"` 不出现在 editor/owner link 响应 — 无数据泄漏。
- 匿名：无 token 直连 data 路由 401（GlobalGuard 在 gate 前，无泄漏面）。
- enforce_for_form 闭环：匿名 shared form 提交 + ADD nobody → 403；PATCH enforce_for_form=false → 200；恢复 true → 403（4/4）。

### 5. 回归 — 通过
- F02：field grant(Qty RECORD_FIELD_EDIT nobody) → editor PATCH Qty 403 / PATCH Name 200；删 grant 恢复。
- F05：variables list/create(key=F03_REG,text)/delete 200。
- F07：snapshots list 200。F10：dashboards list 200。
- F08：extract-ids 中 F08 gate 标记完好（静态），F03 新块与 `isPrivateBase` 检查（:1368）并存无冲突。

### 6. 质量门
- 后端 `tsc --noEmit` exit 0。后端 jest **26/26**（2 suites）。前端 vitest `table-field-permission.test.ts` **14/14**。
- diff 内 `console.*`/debugger/FIXME/TODO 残留 0；`// [CE-EE]` 标记 34 处。

---

## 二、代码复审（整个 diff）

| 审查项 | 结论 |
|---|---|
| fieldPermissionEntityIds 全收集 | ✓ Set 去重；三键匹配（column_name/title/id，R5/R6 交叉重名劫持修复）；system/pk/ForeignKey/isSystemColumn 四重过滤；over-block 安全方向正确 |
| checkPermission 任一拒绝即 403 | ✓ grants 全遍历 any-deny→break；service 层 (entity,entity_id,permission) 唯一防重使顺序无意义；匿名分支（form + enforce_for_form 豁免）独立处理；per-permission 文案泛化（TABLE_ADD/DELETE 独立文案，TABLE 不查 columns）|
| update() resolved-type 三守卫 | ✓ 顺序：validateGrantShape（payload∪existing）→ extractProps → NOBODY+subjects 400 → explicit null/'' granted_role 落 '' 必拒（R4 final-stored-value）→ USER subjects existing-fallback 必拒；NOBODY 时 delete granted_role/subjects + post-write metaDelete subjects 清理 |
| validateGrantShape 共享 | ✓ enum/minimumRole（SDK PermissionMeta）/subjects 形状/nobody+subjects 四类；insert 走 requireSubjectsForUser，update 由 resolved-type 守卫补 |
| v1 VISIBILITY bypass 修复 | ✓ 主 extract 路径 `req.context.ncTableId = model.id`（c7a242cdf3）+ tableName 别名回落解析；AclMiddleware gate `!isServiceUser` + 空权限短路 + 404 遮蔽（R1 生效实测）|
| datas.service:1213 两参调用 | ✓ 非错误 — `BaseModelSqlv2.insert(data, request, trx?)` 第二参即 request；旧代码 `(body, null, cookie)` 把 cookie 传 trx、request=null 致 fail-open，修复正确（实测 v1 view submit 权限链 200/403/404 全对）|
| 缓存移除（R1 cache-free）| ✓ `context.permissions` 请求级复用保留；实例缓存 context 污染由 `req.context ?? this.context` 化解；gate 空清单短路零开销 |
| 仓库卫生 6cc43e0b81 | ✓ 工作树 clean，无 .v1a/.v1b 类残留 |

---

## 三、发现项（无必修 error；按裁决规则逐项定性）

1. **〔语义缺口，待裁决〕公开分享面不消费 TABLE_VISIBILITY** — `packages/nocodb/src/controllers/public-metas.controller.ts` / `public-datas.controller.ts`（消费面缺失，非 diff 引入行）：VISIBILITY nobody 的表，其 shared view 公开 meta（GET /api/v2/public/shared-view/:uuid/meta → 200）与匿名提交（POST …/rows，在无 ADD grant 时 → 200，实测入库 Id=20）均放行。缓解：需持有秘密 uuid；写路径仍受 ADD/enforce_for_form 管（实测 403 闭环）；上游 CE 公开面本无 permission 版 visibility 消费点（消费面=0，非旁路）。建议：记 backlog（public-metas/public-datas 按 table 粒度接 hasTableVisibilityAccess），或明示 fork 裁剪。
2. **〔minor，注释失实〕** `packages/nocodb/src/models/Permission.ts:344`（update() NOBODY 分支）：注释 "R5: also reject bogus granted_role on NOBODY target" — 实际行为是静默 `delete updateObj.granted_role`（清除非拒绝）。行为安全（最终行无 bogus），注释与行为不符，建议改注释。
3. **〔minor，UI 竞态〕** `packages/nc-gui/components/dlg/Table/Permissions.vue`（click handler）：`states[permission].option = opt.value` 在 loadCurrent() 异步完成前点击会 TypeError（渲染层有 `?.` 守卫、handler 无）；窗口期=弹窗打开到 grants 拉回之间。无持久化损坏，建议 handler 加 `?.` 或 states 预填三 key 默认态。
4. **〔minor，UX 语义〕** 同文件 `buildPayload`：SPECIFIC_USERS 选中但未选人时保存 → payload=undefined → 走 DELETE 分支**静默删除已有 grant**（等效重置），无提示。不产生坏状态（空 subjects grant 本会被后端 400），建议提示或禁用保存。
5. **〔fork 裁剪记录〕** 弹窗加载 `enforceForForm` 但无 UI 开关、buildPayload 不发送（恒默认 true=更严格方向）。沿 F02 FIELD 弹窗同款先例，记 fork 限制即可。
6. **〔E3/上游既有缺陷，非 fork error〕** v1 bulk upsert（POST /api/v1/db/data/bulk/noco/:b/:t/upsert）纯 update 批 500：`TypeError: Cannot read properties of undefined (reading 'Id') at BaseModelSqlv2.afterUpdate`。诊断证据：无 grant + owner 直通下复现（与权限无关）；`git blame` 该段 = 上游 commit 4ee772cf42f(DarkPhoenix2704)/58ed76ab443(mertmit)，F02/F03 diff 未触碰。"ADD 拆分不误伤纯 update 批" 的正向验证被此上游 500 阻断，由结构审查（`if (toInsert.length)` 守卫）+ mixed 批 403 实测补证。
7. **〔UX 观察〕** VISIBILITY grant 变更后已渲染的表树不自动刷新（需刷新/重进），配置即时性弱。后端即时生效（实测），纯前端刷新面。

---

## 四、证据要点（file:line）

- extract-ids VISIBILITY gate：`packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1385-1399`（空清单短路 + isServiceUser 豁免 + tableNotFound 404）；ncTableId 主路径 :233-240、别名回落 :1109-1121。
- checkPermission any-deny + 匿名分支：`packages/nocodb/src/db/BaseModelSqlv2.ts:10644-10735`；文案泛化 :10741-10752；fieldPermissionEntityIds 三键收集 :10585-10602。
- ADD 挂点：`db/BaseModelSqlv2/insert.ts:77-85`（single）、`:362-371`（bulk，skipPermissionCheck 块内）；nestedInsert `BaseModelSqlv2.ts:3062-3089`（isFormContext）；bulkUpsert 拆分后 :3870-3878。
- DELETE 挂点：delByPk :2250-2258、bulkDelete :4976-4983、bulkDeleteAll :5545-5552。
- update 三守卫：`packages/nocodb/src/models/Permission.ts:317-401`；validateGrantShape :241-275。
- TABLE 解封：`packages/nocodb/src/services/permissions.service.ts:73-116`（3-key 白名单/Model 校验/synced 拒配/防重）。
- 前端 gate：`Node.vue:428-431/458-462/923`（flag 化）、`useExpandedFormStore.ts:119-127`（去 isEeUI）、`usePermissions.ts:48-53/129-132/158-159`（force/EVERYONE 默认/owner 直通）、`grid/Table.vue:336-348`（legacy ADD）。

**测试数据**：base `pu51tgj44pwzb3k` 留存 nocodb-dev 供复测；残留 grants 0（全部清理）；测试账号 `*-l5@f03t1789434630.test`（密码在 /tmp/f03l5/，未入仓）。
