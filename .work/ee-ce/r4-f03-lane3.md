# R4 F03 Data permissions — lane 3 独立复审报告

**结论:PASS(0 error)** — 1 minor(i18n 缺 key,文案回退,不阻塞功能)+ E3 上游项若干。

- 审查对象:HEAD = main c7672a8b44(F03 实现 7b10716231 + R1/R2/R3 修复链 b28787a54a,之上仅 chore commit)
- 环境::8080 直跑 dist/main.js(会话中后端多次重启,UI token 三次失效,均已重登录续测);:3000 Nuxt dev
- 测试资源:账号 f03r4l3-{owner,editor,creator,viewer}@t.local,base ptm7b638ao413sp(已删,资源已清理)

## 1. 集成测试(全矩阵,API 实测 :8080)

### TABLE_RECORD_ADD(18 项)
- fail-open:无 grant 时 v2 单条/bulk、v1 单条/bulk 全 200 ✅(4)
- nobody:editor/creator v2 单条 403、v2 bulk 403、v1 单条 403、v1 bulk 403;owner 直通 200 ✅(6)
- update 正交:ADD nobody 下 PATCH 记录 200、insert 仍 403 ✅(2;首测 404 为脚本用错路由,`PATCH /api/v2/tables/:id/records/:rowId` 不存在,v2 更新路由为 `PATCH /records` body 带 Id,修正后产品行为正确)
- 删 grant 后下一请求放行 ✅(1)
- role:creator:editor 403 / creator 200 ✅(2)
- user grant(subject=creator):editor 403 / subject 200 ✅(2)
- bulkUpsert 拆分:含插入行批 403 ✅;纯 update 批 500 —— **E3**(见 §5,owner 零 grant 同炸)
- 重复键守卫:同 entity+permission 二次 create 400 ✅(1)

### TABLE_RECORD_DELETE(13 项,全绿)
- v2 单删(body [{Id}])/bulk/owner 直通;v1 deleteAll(`/bulk/:base/:table/all`);v1 单删/bulk;nobody × editor/creator、role:creator、user(subject)矩阵全过;删 grant 后放行;insert 在 DELETE grant 下不受影响 ✅

### TABLE_VISIBILITY(30 项)
- nobody:meta(tableGet)/data v2/data v1/count/aggregate 全 404 遮蔽;creator/viewer/editor 全遮蔽,owner 200;表列表 editor 侧消失、owner 可见 ✅(11)
- role:viewer:viewer 200、editor 200 —— **SDK 语义即 Viewers & up**(evaluatePermission rolePower viewer=2 ≤ editor=4),脚本首测期望写反,产品正确 ✅
- user grant:subject 精确命中 200,editor/creator 非 subject 404 ✅(3)
- Everyone=删 grant 往返,无残留行,访问恢复 ✅(2)
- VISIBILITY gate 消费 v1 fallback 路径(data v1 404 证明 ncTableId v1 fallback 生效)✅

### 校验对称(12 项,全绿)
- create:nobody+subjects 400 / role 缺 granted_role 400 / user 缺 subjects 400 / 非法 granted_type 400 / 非法 permission 400 / role 低于 minimumRole(DELETE+viewer)400 / 跨 base 表 id 400 ✅
- update:role 低于 minimumRole 400 / nobody+subjects 400 / user 缺 subjects 400 / nobody 带残留 role 200 且落库 granted_role=null ✅

### 公开表单 enforce_for_form(6 项,全绿)
- ADD nobody 默认(enforce=true)匿名提交 403;PATCH enforce_for_form=false 后 200;回切 true 恢复 403;删 grant 后 200 ✅(端点 POST /api/v2/public/shared-view/:uuid/rows)

## 2. R3 修复回归(b28787a54a,逐项实测)

| 项 | 结果 | 证据 |
|---|---|---|
| SPECIFIC_USERS 改 users 后保存生效(dirty-flag) | ✅ | UI 切 Specific users 选 creator → Save → API 落库 `granted_type=user, subjects=[usg8jo87n1xpkd50]`(perm76h80x6xqka7j3) |
| SPECIFIC_USERS 单选项默认态可见可选 | ✅ | 弹窗渲染三组单选,Specific users 在 ADD/DELETE/VISIBILITY 三组均可见可点(截图 ui-perms-dialog.png) |
| save 前置校验(空选 SPECIFIC_USERS 全 save 中止) | ✅ 代码审 | `save()` 先遍历 dirty+空选 → `message.error` + return,位于任何写请求之前(Permissions.vue:230-247);与 Field 版同构 |
| owner-role grant 保持 | ✅ | API 造 role:owner → PATCH role:owner → GET 侧 granted_role 仍 `owner`;弹窗 OPTION_FOR_ROLE owner→CREATORS_AND_UP 回显 + originalRole 保留(代码审确认不降权) |
| NOBODY 转换清 granted_role + 复活守卫 | ✅ | PATCH nobody 后 GET granted_role=null;紧接 PATCH `{granted_type:role}` 无 role → 400 "granted_role is required for role grants";带合法 role → 200 |
| user→role 切换清 subjects | ✅ | user grant PATCH role:editor → subjects length 0(注:PATCH viewer 400 是 minimumRole 正确校验,非 bug) |
| bulk 插入性能 | ✅ | 100 行 bulk role:creator grant 下 0.95s vs 无 grant 0.49s(1.9x,同量级;R3 前逐行 Permission.list 放大已消除——TABLE_RECORD_ADD 检查已在行循环外,insert.ts:341-353) |
| duplicate 带 grants | ✅ | 原 base t1 VISIBILITY nobody + duplicate → 副本 /permissions 带 TABLE_VISIBILITY nobody,entity_id=副本新表 id(ma0guhnpmgsi2ct),granted_role=null;importPermissions 逐 grant try/catch + getIdOrExternalId 映射 + subjects 过滤(type==='user' 且 id)代码审确认;export 侧 serializedPermissions 序列化(export.service.ts:724-760)确认 |

## 3. 代码复审(全量 diff)

- checkPermission(BaseModelSqlv2.ts:10620-10734):owner 直通、fail-open、any-deny(`denied` 累积任一即拒,顺序无关)、form 上下文 enforce_for_form、错误文案 per-key(`permissionDeniedMessage`,泄漏面仅表列 title)✅
- extract-ids:主路径 `req.context.ncTableId = model.id`(F03 R2)+ v1 tableName fallback(getByAliasOrId)+ AclInterceptor VISIBILITY gate(isServiceUser 豁免、404 遮蔽)✅
- importPermissions 实装正确(见上表)✅
- Permission.ts:R4 键存在语义(`'granted_role' in data`)、R5 nobody+subjects 对称拒、nobody 清 granted_role(写 null)、user→role 清 subjects 尾置守卫 ✅
- console.log/debugger 残留:F03 全部触达文件(Permissions.vue/usePermissions/Permission.ts/permissions.service/insert.ts/BaseModelSqlv2)无 ✅
- [CE-EE] 标记:diff 中 21 处,后端关键挂点(5 处 checkPermission 调用、VISIBILITY gate、importPermissions、bulk 检查)全覆盖 ✅
- i18n:whoCanAddRecords/whoCanDeleteRecords en+zh 在位 ✅
- 前端 gate:Node.vue blockTableAndFieldPermissions(=false)、useExpandedFormStore 去 !isEeUI、Table.vue usePermissions 提升 setup 顶层(computed 内不再重建 composable)✅

## 4. 回归(F02/F05/F07/F08/F10)

- F02:RECORD_FIELD_EDIT nobody → editor PATCH 403 / owner 200 / 删 grant 200(无 grant 基线 200)✅
- F05:variables create(F03R4L3VAR,key 必须 UPPER_SNAKE_CASE)200/list 200/delete 200 ✅
- F07:snapshot create 200 → status processing→completed → restore 200(新 base_id 返回)→ delete 200 ✅
- F08:base create(type=database)200/get 200 ✅(F08 专属私有语义 UI 面 R4 五路已 pass,本轮 API smoke 确认无回归)
- F10:dashboard create 200/delete ✅

## 5. E3 上游项(有诊断证据,不计 fork error)

1. **v1 bulkUpsert 纯 update 批 500**:editor 带 ADD nobody 403(拆分检查正确),但 owner 零 grant 同请求 500:`afterUpdate ... Cannot read properties of undefined (reading 'Id')`(BaseModelSqlv2.afterUpdate)——与任务书已知上游 E3 完全一致
2. **dev 库脏用户**:base users 列表返回 725 用户(各轮测试账号堆积),Specific users 下拉虚拟滚动需搜索才见成员——环境因素,生产无此形态;非 fork 引入
3. **后端会话中多次重启**:UI xc-auth 三次失效被登出(NC jwt secret 内存随机,重启即轮换),UI 段分三次续测完成;主会话管理行为,非产品问题

## 6. Minor(1 项,不阻塞)

- `packages/nc-gui/components/dlg/Table/Permissions.vue:237`:save 前置校验 toast 用 `t('labels.selectUsers')`,该顶层 key 不存在(实际路径 `objects.permissions.inlineUserSelector.selectUsers`),缺 key 时 toast 显示原文 "labels.selectUsers"。**F02 存量同款**(dlg/Field/Permissions.vue:131,F02 实现 4b26d7a23f 引入,历轮未抓);F03 Table 版由 R3 b28787a54a 复制引入。建议:key 改为 `objects.permissions.inlineUserSelector.selectUsers` 或在 labels 顶层补 `selectUsers`。功能(save 中止逻辑)不受影响。

## 7. 已知 backlog 引用(非本轮新增)

- ⑨ getPermissionSummary 对 TABLE 非 VISIBILITY key 无 grant 显示 Everyone:UI Details 摘要实测「Who can delete records = Everyone」(实际语义 editors & up)——已有 backlog 项,本轮仅复现证据
- ⑧ 公开分享面不消费 TABLE_VISIBILITY:未重测(上游 CE 预埋面缺失,已记录)

## 8. 质量门

- `npx tsc --noEmit`(packages/nocodb):exit 0 ✅
- `pnpm test`(jest,Fork 桶):2 suites / 26 tests 全 PASS ✅

## 9. UI 段(camoufox-cli :3000,独立 session f03r4l3)

- owner 登录 → base → 表右键菜单 Edit table permissions:弹窗三组单选(ADD/DELETE:Creators & up/Editors & up/Specific users/Nobody;VISIBILITY:Viewers and up/Specific users/Everyone/Nobody),默认态 ADD/DELETE=Editors & up、VISIBILITY=Everyone ✅
- Specific users 可见可选(R3 error 2 修复生效);切 user 型 → 搜索选 f03r4l3-creator → Save → API 落库正确(granted_type=user,subject=creator uid)✅
- 重开弹窗回显:ADD=Specific users + creator chip,其余键默认 ✅
- Details → Permissions tab:摘要与 API 一致(ADD=Specific users;VISIBILITY=Everyone;DELETE=Everyone 为 backlog ⑨ 文案)✅
- console error / Nuxt error overlay 双零(vite-overlay false、nuxt-error false、error collector 空数组)✅
- 截图:ui-perms-dialog.png / ui-permissions-tab.png(/tmp/f03r4l3/)

## 实测证据抽样(method path → status)

- POST /api/v2/tables/:t/records(editor,no grant)→ 200;同 + nobody → 403
- DELETE /api/v2/tables/:t/records(body [{Id}],nobody)→ 403;owner → 200
- GET /api/v2/meta/tables/:t(nobody)→ 404;GET /api/v1/db/data/noco/:b/:t(nobody)→ 404
- GET /api/v2/tables/:t/records/count(nobody)→ 404;aggregate → 404
- POST /api/v2/public/shared-view/:uuid/rows(ADD nobody)→ 403;enforce_for_form=false → 200
- PATCH /api/v2/meta/bases/:b/permissions/:id {granted_type:role} after nobody → 400
- POST /api/v2/meta/duplicate/:b → 副本 /permissions 含映射后 VISIBILITY nobody
- bulk 100 行:grant 0.95s / 无 grant 0.49s → 均 200
