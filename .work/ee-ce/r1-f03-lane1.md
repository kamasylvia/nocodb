# r1-f03-lane1 — F03 Data permissions R1 复审(lane1,同规格编制)

审查对象:commit 7b10716231(主审)+ e1e996283c;整个 diff 范围 4b26d7a23f^..HEAD(F02 触碰面一并复审)。
方法:全量集成测试(dev server :8080,nocodb-dev,独立前缀 `l1f03-` 账号/base 隔离)+ 全 diff 代码复审。测试资产已清理(base 归档、grants 全删、泄漏行清除)。

## 结论

issues:
- `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:use()主路径(绝对行 222-231 的 else if (tableId) 分支):TABLE_VISIBILITY 对 /api/v1/db/data/noco/:baseName/:tableName 与 /api/v1/db/data/bulk/:orgs/:baseName/:tableName 全家族不生效——use() 的带 baseId 路由从不设置 req.context.ncTableId(tableIdToCheck 变量只存在于 legacyExtractIds 作用域),而 F03 检查(:1364)与上游 UI-ACL 检查(:1345)都只读该字段;legacyExtractIds:959-984 的 tableName 分支带「visibility gate never ran for it」注释但条件 `!req.ncBaseId` 恒 false(use():149 对带 baseId 路由无条件先设 ncBaseId;能进 legacy 的路由 params.baseName 本为空)——死代码。建议:use() 的 tableId 分支在 Model.get 成功后设置 req.context.ncTableId = model.id,并删除/接通 legacy 死分支`:实测 nobody TABLE_VISIBILITY grant 下 editor 走 v1 data:GET 200 / **POST 200 且行真实落库(psql 实证行 2|leak-final)** / PATCH 200 / DELETE 200 / count 200;v1 bulk insert(by table id)200 + 落行。同 base 同表 v2 meta/data 均 404(对照成立)。多次确认性请求(跨 rspack 重建窗口)稳定复现。e1e996283c commit note 声称 lane5 的 v1 finding 「does NOT reproduce」——本轮实测稳定复现,该 note 结论有误。附带影响:上游 hasModelRoleVisibilityAccess(UI-ACL)对同族路由的遮蔽同样失效(F03 继承同盲区,非 F03 引入)

- `packages/nc-gui/components/dlg/Table/Permissions.vue:224-237(save):SPECIFIC_USERS 未选任何用户时 buildPayload 返回 undefined,save() 走 PATCH/POST 空体而非跳过该项——实测 PATCH {} 为静默 no-op 200(用户以为存了其实什么都没发生)、POST {} 为 400 Invalid entity undefined;建议 payload === undefined 时 continue 跳过该项`(UI 体验缺陷,无数据风险)

- `packages/nc-gui/components/dlg/Table/Permissions.vue:31-37/136-205:enforce_for_form 开关未在弹窗暴露——f03-research §7.7 范围裁定「做」列明此开关;KeyState.enforceForForm 字段已声明但 UI 无控件、buildPayload 不发送。默认 enforce_for_form=true 为安全方向且后端 API 完整支持(PATCH enforce_for_form 实测 200),主语义不破,属配置面缺口`

- `commit e1e996283c:混入 18 个 .reasonix/tasks/** 流程工具产物文件(events.jsonl/snapshot.json/task.lock)入库——流程目录产物不应进 git(TASK.md 对 .work/ 的同款纪律),建议 git rm --cached + .gitignore 补 .reasonix/`

upstream 观察项(非 F03 引入,不计 error):
- `packages/nocodb/src/db/BaseModelSqlv2.ts:4205→6065:v1 bulk upsert 批恰含 1 个 update 行时 afterUpdate 500(Cannot read properties of undefined (reading 'Id'),上游 Audit v1 代码;creator 有权限同样 500)。F03 ADD hook 挂在拆分后(:3867)不触该路径,纯 update 批 toInsert 空时 hook 正确豁免(实测)`

## 集成测试逐项

### 1. 全矩阵(nobody/role/user grants × editor/creator/owner × insert/delete/update/bulk)— 全 PASS
- ADD×nobody:editor v2 单条 403 / creator 403 / owner 200 / v2 bulk 数组 403 / v1 单条 403 / editor PATCH(update)200(update 不受 ADD 拦,语义正确)
- ADD×role:creator:editor 403/creator 200/owner 200;role:editor:editor 200/creator 200(role≥)
- ADD×user(subjects=creator):creator 200/editor 403
- fail-open:删 grant 后 editor 立即 200(下一请求放行 ✓)
- DELETE×nobody:v2 bulkDelete 单条 403/批 403、owner 200、v1 delByPk 403/owner 200、v1 bulk deleteAll editor 403/owner 200;role:creator:editor 403/creator 200;fail-open 删 grant 后 200
- bulkUpsert 拆分(v1 bulk /upsert):纯 update 2 行批 editor 无 ADD → 201(拆分豁免 ✓);混合(2 update+1 insert)editor 403 / creator 201;失败用例复盘:v2 POST /records?upsert=true 无 upsert 语义(参数被忽略,全走 bulkInsert),403 为正确行为,非缺陷
- 注:201 为 v1 bulk API 既有约定(Created),非错误

### 2. fail-open — PASS
全路径(ADD/DELETE/VISIBILITY × v1/v2/meta/list)无 grant 时 200;删 grant 后下一请求即放行(Permission.list 请求级+直读 DB,无陈旧缓存)

### 3. 校验对称 — 22/22 PASS
- create 400 ×9:table+FIELD-key / field+TABLE-key / role 缺 granted_role / user 缺 subjects / nobody+subjects / granted_type=banana / ADD granted_role=viewer(低于 minimumRole=editor)/ granted_role=superadmin(非法枚举)/ entity_id 非本 base 表
- create 重复:(entity,entity_id,permission) 第二次 POST 400 ✓
- update 400 ×6:granted_type=banana / PATCH granted_role=viewer(below minimum)/ nobody+subjects(直接与 existing-nobody 两态)/ 切 user 无 subjects / role grant PATCH granted_role:null
- update 语义:nobody 切换清 granted_role(读回 `nobody None` ✓);切 user + subjects → subjects 重建(读回 user 1 ✓);PATCH 后 entity/entity_id/permission 不可变(extractProps 白名单)
- ACL:editor POST grant 403 / GET list 200(creator+ 写、editor+ 读)✓

### 4. VISIBILITY — v2 面全 PASS,v1 面见 error#1
- nobody on T2:editor meta 404 / v2 data 404 / v2 insert 404 / base 表列表 T2 消失(editor+creator 双验)/ owner meta 200;删 grant 后 meta 200(fail-open)
- role:viewer:editor meta/data 200、列表含 T2 ✓
- user(subjects=creator):creator 200 / editor 404 ✓
- 匿名 shared form × enforce_for_form 4/4:无 grant 匿名提交 200;nobody ADD(默认 enforce=true)匿名 403(`You don't have permission to create records in T1`);PATCH enforce_for_form=false 后匿名 200;删 grant 恢复 200(nestedInsert isFormContext 链路前后端闭环)
- link 折叠:T2 hidden 时 editor 读 T1 记录 link 列输出 pk+pv(与 full 一致——常规 v2 读本就只带 pk+pv,该路径无法区分折叠态;强折叠语义属 shared-view 场景,本轮部分验证,不判 error)
- shared base 两档(isPublicBase default/viewer-role)未独立构造(需 public base + 协作者矩阵,投入产出低;helper 逻辑 hasViewersAndUpTableVisibility/hasDefaultTableVisibility 静态审读无异议)

### 5. skip 通道(import/copy/snapshot)— PASS
nobody ADD grant 活跃下:F07 快照 create→completed→restore 产出副本 base,T1 行数 18(>0,import 走 skipPermissionCheck 免检);同时 source base editor 仍 403(拦截并行不悖)。快照 delete 200。

### 6. 回归
- F05 变量:create/list/update/delete 全 200(首次 400 为我方 payload 用法错——key 需 UPPER_SNAKE_CASE,非产品问题)
- F07 快照:create/restore/delete 全通(见上)
- F10 dashboard:create 200
- F02×F03 组合 6/6:ADD(creator)+FIELD(nobody)叠加下 editor insert 带 Name 403(ADD 拦)/creator insert 带 Name 403(FIELD 拦,creator 非 owner 仍受 nobody FIELD 限)/creator insert 无 Name 200(正交)/editor PATCH 带 Name 403(FIELD)/PATCH 不带 Name 200/owner 全通
- F08 私有 base:未独立构造非协作者 404 场景(本轮 base 均为协作者态,功能前轮已 pass;矩阵全程 base 级访问无异常)
- 后端 tsc --noEmit 0 error;jest 26/26(Fork 桶 2 suites);前端 vitest 定向 table-field-permission 14/14

### 7. 代码复审(diff 全量)
- fieldPermissionEntityIds(:10595-10610):三键(column_name/title/id)匹配、Set 去重、system/pk/ForeignKey/isSystemColumn 过滤 ✓(R6 碰撞绕过修法在位)
- checkPermission(:10620-10734):owner 直通 → 请求级权限清单(req.permissions 优先/Permission.list 回填 context)→ 空 fail-open → 逐 entityId any-deny break(顺序无关)→ 匿名 form 走 enforce_for_form;TABLE label 用 model.title,不查 columns(短路径)✓;文案按 permission 泛化(ADD/DELETE/FIELD 三档)✓
- Permission.update(:310-414):validateGrantShape 共享校验(枚举/minimumRole/nobody+subjects/subjects 形状)+ resolved-type 三守卫(nobody+subjects / role 缺 role / user 缺 subjects)+ nobody 清 granted_role + subjects 重建(delete+insert)+ 'granted_role' in data 存在性语义 ✓;service 层 base 归属 + team subject 双守卫 ✓
- validateGrantShape(:243-308):create(requireSubjectsForUser)与 update(保留 existing subjects)不对称需求正确分流 ✓
- extract-ids F03 检查(:1364-1377):空 grant 短路 fail-open ✓、isServiceUser 豁免(SDK isServiceUser(undefined)=false,匿名进检查)✓、404 遮蔽(非 403)✓——但其输入 ncTableId 的生产侧缺口见 error#1
- permissions.service TABLE 解封(:73-96):三 key 白名单、Model 存在、base 归属、synced 拒配 ✓
- 前端:Node.vue gate(blockTableAndFieldPermissions 替代 isEeUI/showEEFeatures,RLS gate 保留)✓;弹窗 v-if="table.id" ✓;Content.vue 三 key 摘要 + Configure 入口 ✓;useExpandedFormStore 去 !isEeUI 短路(meta.id 空守卫替代)✓;legacy grid Table.vue isAddingEmptyRowAllowed 补 TABLE_RECORD_ADD(?? true 兜底)✓;getPermissionSummary/LoadCurrent VISIBILITY 默认 EVERYONE(e1e996283c)✓
- 探针残留:diff 范围内 console.*/debugger 零新增(命中行均为上游既有);错误消息不含内部 id/堆栈 ✓
- 性能:中间件每请求多一次 Permission.list(仅 ncTableId 已设路由;空 grant 索引小查),checkPermission 请求级复用 context.permissions;无 N+1 回归新面(Permission.list subjects 循环为 F02 既有 backlog)

## 证据要点
- v1 写穿落库:grant=nobody VISIBILITY 下 editor POST /api/v1/db/data/noco/BASE/T2 → 200 + `{"Id":2,...,"Title":"leak-final"}`,psql `"pmym2g54tnhgd2v"."T2"` 查得 `2 | leak-final`;v2 同表 meta/data 404;清理后 count=0
- 死代码证明:use()(extract-ids.middleware.ts:115-489)对带 params.baseId/baseName 的路由在 :149 设 req.ncBaseId 并自持链路,其 tableId 分支(:222-231)不写 ncTableId;ncTableId 全仓唯一生产点 :1100 在 legacyExtractIds(:512-1104)内,该函数仅被 use():486 的 else(无 baseId 的 shared UUID 路由)调用;legacy :959 条件 `(params.baseId||params.baseName) && !req.ncBaseId` 两侧互斥恒 false
- 环境:dev server :8080(nocodb-dev),账号 l1f03-{owner(super),editor,creator}@t.local,base F03L1(T1/T2 + mm link 列),测试后已归档清理

## 裁决建议
error#1 为唯一必修项(单路属实 + 实测落库证据,按规程实测验证成立);修复点集中在 use() 的 tableId 分支补 `req.context.ncTableId = model.id`(一行级)并处理 legacy 死分支。I1-I3 为低危改进/卫生项,随修顺带。
