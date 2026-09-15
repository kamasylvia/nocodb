# F03 Data permissions — R1 复审报告(lane5-ext,外部阵容补位路,独立编制)

审查对象:commit 7b10716231(HEAD,工作树 clean;:8080 dev server 即该 commit 构建)+ 4b26d7a23f^..HEAD 全 diff(F02 触碰面)。
注:`r1-f03-lane5.md` 文件名在本轮已被其他路先占(14:39 存在,本路未读其内容),按防覆盖规则另存本文件。

## 结论

issues 列表(2 error + 4 观察):

1. `packages/nc-gui/components/dlg/Table/Permissions.vue:26,60-61`:`getPermissionLabel` 未从 usePermissions() 解构(optionLabel 内直接引用,script setup 无此绑定)→ 渲染期 ReferenceError → 三个 key 的全部选项按钮渲染为空 `<!---->`,配置弹窗实际不可用(仅标题 + Cancel/Save)。UI 实测:camoufox 打开弹窗,role=dialog 内 button 仅 Cancel|Save,section innerHTML 全为 `<!--v-if-->`/空 div;对照 F02 `dlg/Field/Permissions.vue:26` 正确解构了 `getPermissionLabel`。修复:补解构(照抄 F02)。
2. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1364`(F03 新增块):TABLE_VISIBILITY gate 锚定 `req.context.ncTableId`,而该值仅在 legacyExtractIds(无 :baseId/:baseName 参数的路由)赋值(1099-1100)。v1 alias 数据族 `/api/v1/db/data/:orgs/:baseName/:tableName*`(data-alias.controller)带 :baseName → 走主链 → ncTableId 永不赋值 → gate 整体跳过 → 隐藏表数据泄漏。commit message 声称 "hidden tables 404 on data routes too" 仅对 v2/:viewId 族成立。实测(VISIBILITY nobody on TblA,editor):`GET /api/v1/db/data/noco/<baseId>/<modelId>` → 200 且 6 行全量;`.../groupby` → 200;`POST .../records`(v1 insert)→ 200;同刻对照 v2 data 404、meta 404、表列表隐藏、owner v1 200。修复:主链 `else if (tableId)` 分支(约 225-235)解析 model 后补 `req.context.ncTableId = model.id`(tableName 走 getByAliasOrId),对齐 983 处注释声明的意图。

观察(不计 error):

- O1(上游遗留,非 F03 引入):v1 alias 按 title 寻址恒 404(主链 `Model.get(tableId)` 仅按 id),owner 零 grant 同样 404;`git show 4b26d7a23f^` 同构(extract-ids 在 F02/F03 范围内仅新增 F03 块)。v1 族因此仅剩 by-ID 可用 → 放大 issue 2 泄漏面。建议单独修或记 fork 限制。
- O2(上游 CE bug,非 F03):v1 alias bulkUpsert 纯 update 批 500 `Cannot read properties of undefined (reading 'Id')`(afterUpdate BaseModelSqlv2.ts:6065 ← bulkUpsert:4205 `existingRecords[0]` undefined;existingRecords 初始 [] 3708,仅 merge 分支回填 3781,PK 匹配路径不回填)。`4b26d7a23f^` 同在;F03 ADD hook 被 `if (toInsert.length)` 跳过,与本 bug 无关(插入批同函数 201 正常)。merge-fields(v3)upsert 工作正常。
- O3(UI 语义,minor,随 issue 1 一并修):无 grant 时 VISIBILITY 默认态被置为 EDITORS_AND_UP(语义应为 EVERYONE;该值又不在 visibilityOptions 内 → 无选中项;usePermissions.getPermissionSummary 同病,Content.vue 摘要会显示错默认);此态下 buildPayload 返回 undefined → save() 走 PATCH/POST undefined body → 400 toast。
- O4(产品语义待裁):shared-view 族(/api/v2/public/shared-view/*)同样不设 ncTableId,VISIBILITY nobody 不遮蔽匿名表单 meta/submit(均 200;anon rows GET 无 grant 基线即 404,不构成遮蔽证据)。匿名提交仍受 TABLE_RECORD_ADD + enforce_for_form 把关(实测 403/200/双向),泄漏面仅为"表单链接可达性"。若产品要求隐藏,与 issue 2 同点修复。

## 集成测试结果(nocodb-dev @ :8080;base pp3c90uo1sqjk17/F03LANE5;TblA=m2s4s1vw05qg5hr,TblB=mb0i8ww2gyi2pqr;账号 f03l5own/ed/cr/ed2@ce-ee.local,base 角色 owner/editor/creator/editor)

全矩阵(grants × roles × ops)——除 issue 2 外分界全部正确:

| 项 | 结果 |
|---|---|
| ADD role:editor → ed/cr/ed2/bulk 全 200 | PASS |
| ADD role:creator → ed 403 / cr 200 / own 200 | PASS |
| ADD nobody → ed 403 / cr 403 / own 200(文案 "You don't have permission to create records in TblA") | PASS |
| ADD user:[ed] → ed 200 / cr 403 / ed2 403;user:[ed,ed2] → ed2 200 | PASS |
| v1 alias/nested insert 挂点:ADD nobody → 403;user:[ed] → ed 200 | PASS |
| DELETE role:editor/creator/nobody × v2 `DELETE /records`(单+批统一入口) | PASS(403/200 分界全对) |
| v1 bulkDeleteAll(`DELETE /api/v1/db/data/bulk/noco/:b/:t/all`)nobody 拦截/放行、失败-开放恢复 | PASS |
| v3 merge-upsert 拆分语义:ADD nobody 纯 update 批 200 "updated"/insert 批 403/删 grant 后 insert 200 | PASS(证 hook 位于拆分后,不误伤纯 update) |
| VISIBILITY nobody → ed v2 data 404 / v2 meta 404 / 表列表隐藏 / cr meta 404 / own 200;删 grant 恢复 200 | PASS(v1-by-ID 泄漏见 issue 2) |
| 校验对称(全 400,文案精确):nobody+subjects / role 缺 granted_role / user 缺 subjects / 非法枚举 admin / ADD·DELETE role viewer(<editor minimumRole)/ 非法 key TABLE_RECORD_EDIT / FIELD key 挂表 / 不存在表 / 重复 (entity,id,perm) | PASS |
| update 对称:nobody+subjects 400 / granted_role null 400 / 非法枚举 400 / user 缺 subjects 400 / switch nobody 200 且 subjects 清空 | PASS |
| 匿名表单:ADD nobody(enforce_for_form=true)→ 403;PATCH false → 200;ADD user:[ed] → 403;清理后 200 | PASS |
| VISIBILITY 匿名:shared-view meta/submit 200(不遮蔽,O4) | 见 O4 |
| link 折叠:TblB 隐藏时 ed nested BLink 仅 Id+Title(默认嵌套形,owner 同形,无差分泄漏);ed 直读 TblB meta/data 404;`fields=BLink.Notes` 双方同拒 | PASS |
| fail-open:零 grant 全路径 200;grant 删除后下一请求即放行(ADD/DELETE/VISIBILITY 逐项) | PASS |
| F02 回归:RECORD_FIELD_EDIT nobody on Qty → ed PATCH 带 Qty 403 / 不带 200 / own 200 / 删 grant 后 200 | PASS |
| F05:variable POST(key/value)+GET+DELETE | PASS |
| F07:snapshot POST → processing → completed | PASS |
| F08 smoke:协作者 base meta 200(F08 已 pass,diff 未触其路径) | PASS |
| F10:dashboard POST/GET/DELETE | PASS |
| UI 段(camoufox-cli):owner 登录 → 打开 F03LANE5 → TblA 右键菜单含 "Edit table permissions"(gate 已解)→ 弹窗三 section 渲染 → **选项按钮全空 = issue 1** | 见 issue 1 |

## 代码复审要点(整个 diff)

- fieldPermissionEntityIds:三键(title/column_name/id)全收集 + Set 去重 + system/pk/ForeignKey/isSystemColumn 过滤;R6 title↔column_name 碰撞全收集语义(over-block 安全向)✓
- checkPermission:owner 直通 / 无 grant fail-open / any-deny 顺序无关 / 匿名 form 语境 enforce_for_form / TABLE label 短路径 + permissionDeniedMessage 按 key 泛化 ✓
- Permission.update():resolved-type 三守卫先于写;switch nobody 清 granted_role;subjects 重建后 nobody 兜底清 subjects ✓;validateGrantShape create/update 共享(enum/minimumRole/subjects 形状/nobody+subjects 对称)✓(实测 400 全对)
- Permission.list 刻意免 NocoCache(注释 R1)+ context.permissions 请求级复用 ✓;extract-ids 空 grant 短路(fail-open 零开销)✓
- permissions.service:TABLE 三 key 白名单 + Model 存在 / base 归属 / synced 拒配 / 重复拒 ✓
- insert.ts bulk ADD hook 在 `!skipPermissionCheck` 块内(import/copy/snapshot skip 通道成立);nestedInsert isFormContext=isPublicForm ✓;delByPk/bulkDelete/bulkDeleteAll 挂点与调用方核对一致 ✓
- 前端:Node.vue gate flag 化(去 isEeUI/showEEFeatures)、dlg v-if 解 isEeUI、Content.vue 三 key 摘要+Configure、useExpandedFormStore 去 !isEeUI 短路、legacy Table.vue isAddingEmptyRowAllowed 补 TABLE_RECORD_ADD ✓;DlgTablePermissions 见 issue 1/O3

## 静态检查

- `npx tsc --noEmit -p tsconfig.json`(packages/nocodb):exit 0,0 错误
- jest `(Integration|Source|Fork)\.spec\.ts$`:2 suites,**26/26 passed**
- diff 内 console.log/debugger 残留:0(grep 全量);错误消息无内部信息泄漏

## E3 外部限制(有诊断证据,不计 error)

- 会审窗口内多路循环 kill/重启后端(bash pid 39667/45040/37487/31005 等,`pkill -f rspack/dist/main.js`),造成成批 curl 000 连接中断与 JWT 失效(重启后 NC_AUTH_JWT_SECRET 重生成);全部用重试+单调用内完成消除,无断言缺失。
- 本机沙箱间歇 `failed to change group ID`(zsh $() 内 python3 随机失败),改文件中转后完成。
- 未测项(代码核对覆盖):synced 表拒配(dev 无 synced 表)、service user 豁免(未 provisioning automation 用户)、duplicate 仅拷可见表、undo 路径、viewer 角色用户(lane 矩阵只要求 ed/cr/own)。

## 证据

- /tmp/f03lane5/:batteryA.out、batteryB.out、batteryC.out、batteryD.out、batteryF.out、ui1.png、ui-dlg.png、grants.json、edlist.json/ownlist.json
- 关键对照(VISIBILITY nobody 生效期间):`GET /api/v1/db/data/noco/pp3c90uo1sqjk17/m2s4s1vw05qg5hr` → 200 rows=6;同刻 `GET /api/v2/tables/m2s4s1vw05qg5hr/records` → 404;`GET /api/v1/db/data/noco/pp3c90uo1sqjk17/TblA` → owner 亦 404(O1)

