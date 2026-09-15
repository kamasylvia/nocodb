# r3-f02-lane3 — F02 Edit field permissions R3 收敛轮(第 2 轮 0 error 判定)

## 结论

**PASS**(0 error;2 条轻微观察项,均非功能缺陷,见文末)

## 覆盖面

审查对象:4b26d7a23f(实现)+ e85a421d92(R1)+ 3b9dcbdbc6(R2)。集成测试在 dev server(localhost:8080 / nocodb-dev,PG 18.2)实测;代码复审覆盖 R2 diff + 三 commit 累计(22 文件,+1554/-53)。

## R2 修复验证(逐项)

1. **探针零残留** ✅ 源码 grep `[F02-Q/R/P/Z]` + console.log 于 F02 触碰后端文件 = 0 命中;`logs/backend.log`(覆盖本轮全部测试请求)0 命中。前端触碰文件的 console.*(ColumnMenu.vue:377、useViewData.ts:176/240/307)经 `git show 46e5c81727` 比对为上游既有,非 F02 引入。
2. **PATCH granted_role 校验** ✅ PATCH `granted_type:role, granted_role:"viewer"` → 400(below minimum role);"bogusr" → 400(invalid);"editor" → 200。insert/update 共用 `validateGrantShape`(Permission.ts:210/312)。
3. **nobody 清 subjects** ✅ user grant(subjects 1 行,editor 在列可写 200)→ PATCH nobody → DB `nc_permission_subjects` 0 行;回转 `granted_type:user` 无 subjects → 400。nobody 拒 editor 写 → 403;owner 直通 → 200。
4. **isPublicForm 语义收敛** ✅ 全仓置位点仅 `public-datas.service.ts:827`(匿名公共表单);`datas.service.ts:1214-1220` 认证 view-submit 不置位,注释准确。实测:匿名公共表单提交受限字段(enforce_for_form=true 默认)→ 403;PATCH `enforce_for_form:false` → 200 落值(表单豁免);豁免不外溢——editor API 直写同字段仍 403;认证用户走 view-submit 无 isPublicForm 旁路。
5. **permissionList editor+** ✅ editor `GET /api/v2/meta/bases/:id/permissions` → 200(acl.ts:553-558);create/update/delete 保持 creator+。
6. **loadPermissions(force)** ✅ 代码面确认 dialog save/delete/reset 走 force refetch(前端无浏览器环境,未 UI 实测;逻辑正确)。

## 写入路径全扫(nobody grant on Secret / editor 身份)

**受限字段 → 全 403(12 路)**:
v2 单条 insert / v2 数组 insert / v2 PATCH / bulkUpsert(`/api/v1/db/data/bulk/:o/:b/:t/upsert`)/ bulkUpdate / bulkUpdateAll(`.../all?where=`)/ v1 单条 insert / v1 bulk insert / v1 PATCH / link addChild v2(`POST /api/v2/tables/:t/links/:col/records/:row`)/ link v1 relationDataAdd(`.../1/ln/:colId/1`)/ 嵌套 insert 带 T2Link(链列受限)/ 嵌套 insert Secret+T2Link 双受限。错误文案含字段 title("You don't have permission to edit the field Secret/T2Link")。

**干净路径 → 200/201**:v2 单条/数组 insert(仅 Title)、v2 PATCH、bulkUpdateAll(仅 Title)、v1 单条 insert、move(201,order 系统列豁免)、owner 加链 201、删链 grant 后 editor 加链 201。

**上游既有 bug(非 F02,不计数)**:bulkUpsert 干净路径(仅 Title)→ 500 `Cannot read properties of undefined (reading 'Id')` @ `BaseModelSqlv2.ts:6013` afterUpdate(prevData undefined)。对照实测:owner 身份 + 无任何 grant 的新建表 T3 同样 500 → 与 F02 无关(F02 未触碰 afterUpdate;owner 路径 checkPermission 直接 return)。受限路径的 403 在该崩溃点之前正常拦截。建议后续单独立项修复(上游 Audit v1 引入的 bulkUpsert update 段 prevData 读取缺陷)。

注:v1 别名路由用表 title 查 404、用表 id 正常(如 T1 vs mucazwthzscoq94),为上游别名解析行为,与 F02 无关。

## skip 通道

- **F07 快照** ✅ owner 在 grants 存在下建 snapshot → `completed`;副本 base 含 T1/T2/T3,行数据完整(受限 Secret 值 anon-c/val-c、owner-ok 均在)。
- **duplicate** ✅ owner 复制含 grants 的 base → 副本数据完整(3 行含 Secret 值)。
- **undo** ✅ editor 干净字段 `?undo=true` 写入/回放 200/200;涉受限字段 undo → 403(一致语义:undo 不为无权用户越权,owner 不受限)。

## 回归

- 无 grant CRUD(editor):insert/PATCH/delete 全 200;grants 存在时不误拦干净列 ✅
- F05 variables:create(key/value)+ list 200 ✅
- F07 snapshots list 200 ✅(见上)
- F10 dashboard create 200 ✅
- F08 base type=`database` 完好 ✅
- F01:纯前端 UI gate(useCanvasTable/useCopyPaste),无后端 API 面,不适用 API 抽测(F01 已在其自身轮收敛)
- 后端 `npx tsc --noEmit` exit 0 ✅
- 后端 jest:**26/26**(2 suites)✅

## 性能

editor PATCH Title ×10,1 grant 存在 vs 无 grant:稳态 ~57ms vs ~48ms,**+9ms/写 = 常数级**(每次写多一次 permissions meta list + 每 grant 一次 subjects 查询;非逐行/逐列放大)。fail-open 路径(无 grant)仅多 1 次索引 meta 查询。

## 代码复审

- `datas.service.ts:1214-1220` 注释准确:说明有意的 isPublicForm 不置位及理由 ✅
- `checkPermission` 匿名分支(`BaseModelSqlv2.ts:10580+`):语义正确——nobody/role grant 均经 SDK `evaluatePermission`;`enforce_for_form === false` 跳过;any-denial-blocks 无序依赖。观察:public-datas 在置 isPublicForm 前先盖 ANONYMOUS service user,故 `!user` 分支实际不可达——防御性代码,无行为影响,不算问题
- service 校验链:entity 枚举 / entity_id 列存在性 / synced 列拒配 / permission 枚举 / 仅 RECORD_FIELD_EDIT / 拒 TABLE entity / (entity,entity_id,permission) 去重 / team subject 拒 / base 归属校验(update/delete),全在 ✅
- controller:v1/v2 双路径 + @Acl 四 op 注册完整 ✅
- Permission.update validateGrantShape:合并 existing 值校验,subjects 传 data.subjects(未传时跳过 subject 形状校验,保留旧行)——正确
- Console 残留:后端 F02 触碰文件 0;前端触碰文件 console 为上游既有(git 基线比对)✅

## 观察项(非 error)

1. `packages/nocodb/src/controllers/permissions.controller.ts:20`、`packages/nocodb/src/services/permissions.service.ts:16`:头注释仍写 "creator+ only" — R2 已将 permissionList 开至 editor+,与 acl.ts:553-556 内新注释不一致。建议:两处措辞改为 "permissionList editor+(read-only);create/update/delete creator+"。
2. `packages/nocodb/src/models/Permission.ts:99-115`:Permission.list 为每 grant 行单独查 subjects(N+1)。当前 grant 数量级小、查询走索引、实测常数级(+9ms),可接受;若未来 grant 数量增长,可合并为单次 subjects 联查。

## E3

无。
