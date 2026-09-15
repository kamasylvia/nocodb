# R2 F03 lane2 — 功能全量集成测试 + 整个 diff 代码复审(收敛轮)

> 审查对象:7b10716231(F03 主实现)+ 2f5a57b0d3(R1 修复)+ e1e996283c(VISIBILITY 默认)+ 0a3e5fdab4(dialog 渲染修复)。
> 环境:localhost:8080(nocodb-dev,server 含 R1 修复,bundle 23:56 构建 = 源 mtime 后 40s);隔离测试 base `poto5fq94rforiz` / table `mkn1myetx82qqd6`(editor/creator/owner 三号,owner psql 提权 super)。
> 权限行测试全部走 API;multi-grant 用 psql 插新行(任务书允许)。

## 结论

**issues(不 PASS)**

1. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:1107-1116(2f5a57b0d3 新增 catch-all):R1 修复无效——v1 data-alias 家族(/api/v1/db/data/noco/:baseName/:tableName 及 bulk 变体)在 nobody TABLE_VISIBILITY grant 下仍 200 读数据:建议把 ncTableId 赋值搬进 use() 主分支(该家族带 :baseName,走 136 的 if 主体,legacyExtractIds 及其中的 catch-all 永不执行;use() 主分支从未写 req.context.ncTableId,gate@1378 因 ncTableId 为空被跳过)`
2. `.v1a/.v1b/.v1c(仓根):2f5a57b0d3 把 3 个 API 测试响应残留文件加入 git 跟踪,commit message 却写"remove stray PATCH/-X junk files";未入 .gitignore:建议 git rm --cached + 忽略`
3. `packages/nocodb/src/models/Permission.ts:394-400:update 仅传 granted_type:nobody(PATCH 不带 granted_role key)时,delete updateObj.granted_role 不生效,DB 行残留 granted_role='editor'(subjects 会清,role 不会;delete 只能删 payload 里存在的 key);功能惰性(SDK evaluatePermission:nobody 恒 false)但违反 fork 自定 R5 不变式"nobody grants carry no role":建议 targetType===NOBODY 时对 updateObj 显式写 null 而非 delete`
4. `packages/nc-gui/components/dlg/Table/Permissions.vue:enforce_for_form 开关未在 UI 暴露(KeyState.enforceForForm 记录了但 buildPayload 从不发送、模板无控件),公共表单放行开关只剩 API 裸路径;f03-research §7 范围项 7 明列"enforce_for_form 开关":建议补一行开关(F02 字段弹窗已有样板)`

minor/observation 不计 error:
- OBS1(上游,非 fork):`BaseModelSqlv2.ts bulkUpsert` PK 分支 `existingRecords` 从未赋值(只填 `dbRecords`,3806-3817),单行 update upsert 必 500(afterUpdate 读 `existingRecords[0]` 的 undefined;上游 eca7ea64306/4ee772cf42f,2026-04)。本次实测纯 update upsert 返回 500。fork 未触碰该逻辑,不 charge F03,但 FYI 修复面在上游同步。
- OBS2(上游):v1 data-alias 按**表名**(title)访问在 use() 主分支 `Model.get`(id-only)下 404(blame mertmit 2026-01-10)——即 title 形式请求到不了 gate,by-id 形式才是 E1 的实际暴露面。

## 逐项结果

### 1. R1 修复验证(重点)
| 项 | 结果 |
|---|---|
| v1 GET /api/v1/db/data/noco/:baseId/:tableId,nobody VISIBILITY,editor | **200(应 404)→ E1**;count/read 同 200;v1 bulk-alias POST 读也 200 |
| v2 records/meta 同 grant | 404 ✓(gate 本身工作) |
| owner 同路径 | 200 ✓(owner 直通) |
| creator | 404 ✓(v2)/200(v1,E1 同源) |
| grant delete 后 | 下一请求 200 ✓(fail-open) |
| 重复 grant(API) | 400 "A permission grant already exists" ✓ |
| multi-grant any-deny(user 放行 + psql 插 nobody 行) | editor/creator 403、owner 200 ✓;删 nobody 行后 editor 200 ✓(顺序无关,任一拒即拒) |
| R1 附带修复:entity=dashboard × TABLE_RECORD_ADD | 400 "Entity dashboard is not supported" ✓ |

Root cause(静态钉死):`use()`(117-490)在 `baseId=params.baseId||params.baseName` 存在时走主分支(136),仅其 `else`(483)调 `legacyExtractIds`;catch-all(1107)与全部 `req.context.ncTableId` 赋值(1100/1113)都在 legacyExtractIds 内 → 对 v1 data-alias 家族是死代码。bundle 核对:dist/main.js:192193 含该逻辑但运行时不可达。

### 2. 全矩阵
- TABLE_RECORD_ADD:nobody×(editor/creator 403,owner 200)、role:editor×(editor/creator 200)、role:creator×(editor 403,creator 200) ✓;v2 bulk insert、v1 insert 单条同语义 ✓。
- TABLE_RECORD_DELETE:nobody:v2 数组删(单/批)403 ✓、v1 单删/bulk 删/`/all` 全删 403 ✓、owner 200 ✓;role:editor:editor v1 删 200 ✓;role:creator:editor 403/creator 200 ✓;grant delete 后 editor 200 ✓。
- UPDATE 不受 ADD/DELETE grant 影响:editor v2 PATCH(数组/单条)与 v1 PATCH 在 DELETE-nobody 下全 200 ✓,grant 删后 200 ✓。
- bulkUpsert 拆分:role:creator grant 下 editor 纯 update 批不被 ADD 拦(未 403;终态 500 系 OBS1 上游 bug)、含新行批 403 且文案 "You don't have permission to create records in Data" ✓。
- user-grant:subject=editor 时 editor 200/creator 403/owner 200 ✓。
- VISIBILITY 列表遮蔽:nobody grant 下 editor 的 base tables 列表无该表 ✓,owner 仍见 ✓,删 grant 恢复 ✓。

### 3. fail-open
无 grant 全路径 200 ✓;grant delete 后下一请求放行(v1 data、v2 delete、visibility 列表三处验证)✓。

### 4. 校验对称(create/update × 全排列)
- create:nobody+subjects 400 ✓;role 缺 granted_role 400 ✓;user 缺 subjects 400 ✓;非法 granted_type 400 ✓;role:viewer 于 ADD(低于 minimumRole)400 ✓;role:viewer 于 VISIBILITY(恰为 min)200 ✓;entity=dashboard 400 ✓;TABLE key 于 FIELD 400 ✓;非 table key 于 TABLE 400 ✓;未知 entity_id 400 ✓。
- update:PATCH nobody+subjects 400 ✓;granted_role='' 400 ✓;低于 min 400 ✓;role→user 无 subjects 400 ✓;role→nobody 200 且 subjects 清空 ✓(G17:granted_role 残留,见 issue 3);role→nobody 后再→role 无 granted_role 被 400 拒 ✓。

### 5. 公共表单(shared form,匿名)
- 无 grant 匿名提交 200 ✓;ADD-nobody + enforce_for_form=true(默认)→ 403 ✓;PATCH enforce_for_form=false → 200 ✓;删 grant → 200 ✓;同一 grant 下认证 editor 直插 v2 仍 403 ✓(isFormContext 只作用于表单路由)。

### 6. 回归
- F05:variable create(key/value/type=text)200 ✓、list 200 ✓。
- F07:snapshot create 200(返回 snapshot_base_id,副本链路活着)✓。
- F08:新建 is_private=true base,非成员 editor/creator meta 404 + tables 404 + base 列表不含 ✓,owner 200 ✓。
- F10:dashboard create 200 ✓。
- F02:field nobody grant 创建 200,editor 改受限字段 403,删 grant 后 200 ✓。
- tsc --noEmit:0 错误 ✓;jest(Fork 桶):26/26 ✓。
- 探针扫描:F02+F03 全 diff 无 console.log/debugger 残留 ✓;错误文案不含内部 id/堆栈 ✓(403/404 文案仅表名/通用语)。

## 代码复审补充(未入 issues 的核对点)
- fieldPermissionEntityIds:Set 去重、system/pk/FK/isSystemColumn 四重过滤、column_name/title/id 三键全匹配 ✓(R6 全收集语义在)。
- checkPermission:owner 直通→reqContext 权限清单(修过 F02 缓存坑)→空清单短路→逐 entityId 多 grant any-deny→匿名 isFormContext/enforce_for_form 分支→TABLE 分支 label=this.model.title ✓。
- validateGrantShape 共享:create(requireSubjectsForUser)/update 对称;minimumRole 强制经 PermissionMeta ✓。
- update() 三守卫顺序(resolved-type→nobody+subjects→final-stored granted_role→user subjects)在实测 G11-G16 下成立 ✓。
- permissions.service:create 的 entity×permission 配对白名单 + Model 存在/base 归属/synced 拒配 ✓;update 不接受 entity/permission 变更(extractProps 白名单)✓。
- 中间件 gate:空权限清单短路 ✓、isServiceUser 豁免 ✓、404 非 403 ✓(仅 ncTableId 缺失面失守 = E1)。
- 前端:DlgTablePermissions 三 key 状态机/VISIBILITY 默认 EVERYONE/save 的 PATCH+POST+DELETE 混合循环/undefined payload 跳过(R1 修复在)✓;Node.vue gate flag 化 ✓;useExpandedFormStore isEeUI 短路已除 ✓;legacy grid Table.vue 补 TABLE_RECORD_ADD ✓;usePermissions TABLE 默认 EVERYONE ✓。

## 证据文件
- 测试脚本/产物:`.work/ee-ce/r2-lane2-tmp/`(lib.sh=phaseA、matrix.sh、matrix2.sh、matrix3*.sh、phaseC/D/E/F.sh、confirm_v1*.sh、dbg*.sh)
- 测试 base:poto5fq94rforiz(mkn1myetx82qqd6);私有 base 抽测:prfblb4q6w3vv3j;快照:snapsuyn4ak0xek43n
- 遗留:测试 base/快照/dashboard 等副本留在 nocodb-dev(均为 f03/r2l2 命名,可后续清理);库内权限行已清零

lane2 / 2026-09-15
