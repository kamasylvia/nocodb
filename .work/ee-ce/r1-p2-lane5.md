# F09 P2 R1 — lane 5(UI + 安全重点路)报告

**结论:4 error + 2 minor** — paste createSync 双断点(E1/E2)+ selected_fields 减腿 500(E3)+ 增腿 dest_column_id 落错致新列数据永不同步(E4)。detach 转正 / 源列类型漂移传播 / 灰区复检 / ACL 回归 / P1 引擎回归全过。质量门 tsc 0 + jest Fork 桶 41/41 + 双 SFC Vite URL 200。UI 活体:向导 paste 流走通至 Create(被 E1 阻断,toast 截图留证)、树菜单 Convert to regular table 全程活体验证。

基线 a4959c27cd(P2 实现批)。审查时间 2026-09-18 深夜,后端 :8080 = P2 dist。

## 0. 环境热修(指挥路授权内)

运行 dist(06:32)早于 P2 commit(22:24)、且 `sourceInputMode`/`sharedViewUrl` 0 命中 → 按派遣令执行热修:源仓 rspack 构建(新 dist 22:29,P2 特征 4/5/2/4 命中)→ rsync → `dev-backend-internal.sh stop/start` → health 200(经 `/api/v1/health`,v2 无 health 路由)。重启一次,授权范围内。

另:测试基建发现 **F08 后 signup 用户 workspace 级 No Access,无法直接建 base**——用既有基础设施账号(f01e2e@,仅发 base 邀请,不建资源)搭桥;所有测试资源 title 均带 `f09p2r1l5` 前缀,账号 f09p2r1l5-api/api2/ui(UI/API 分离)。

## 1. paste 模式(P2 §1)—— **2 error**

过:
- resolve-link:URL 分支(`/nc/view/<uuid>`,api2 无源 base 权限)200 + passwordProtected:false + 源坐标;裸 uuid 分支 200;非法输入 400
- 密码三态:passwordProtected:true(无密码)/ 错密码 400 / 对密码 false;createSync 无密码 400「password protected」、错密码 400
- allow_sync 强制:关后 resolve 400 / createSync 400 / **已有 paste sync 的 resync 复检 400**(灰区 §5 一并过)
- sourceSchema paste 分支:passwordProtected 预览语义正确(无密码只返 `{passwordProtected:true}`)
- T1a-c 实测 13 项断言 PASS 清单见 /tmp/f09p2r1l5/t1.sh 输出

**E1 — createSync paste 缺 sourceTableId 时必 400「Shared view not found」**
`table-syncs.service.ts:460-464`:`Model.get({...context, base_id: view.base_id}, sourceTableId)`,paste 分支 sourceTableId 可选,未传时 `Model.get(ctx, undefined)` → null → 误报 'Shared view not found'。**前端 CreateNewSync.vue paste 分支(:141-146)恰好不传 sourceTableId**(只传 sourceInputMode/sharedViewUrl/sharedViewPassword)→ 官方向导路径 100% 踩中。修复:sourceTableId 缺省回退 `view.fk_model_id`。UI 活体证据:`shots/paste-create-toast.png`(红 toast "Shared view not found",视图存在且密码正确)。

**E2 — createSync paste 的 `srcModel.getColumns(context)` 用 dest context → 必 400「Source table has no syncable columns」**
`table-syncs.service.ts:465`:`await srcModel.getColumns(context)`(context = dest base)。`Column.list` 的 metaList2 按 (workspace_id, base_id) tenant 过滤(`Column.ts:706-710`)→ dest base 下查源表列 = 空 → `getMirrorableColumns` 空 → :501 400。修 E1 后传对 sourceTableId + 对密码仍 400(实测链:400 'password protected' → 对密码 → 400 'no syncable columns')。对比:sourceSchema paste 分支用 srcContext(:297-303)正确。修复:改用 `sourceContext`(paste 分支的 `{workspace_id: view.fk_workspace_id, base_id: view.base_id}`)。
**影响:E1+E2 合计 = paste 建同步完全不可用(API 与 UI 双断);paste resync 拉数与「paste 不复检 base 权限的 resync 面」被阻断记 E-blocked(resync 复检代码审:allow_sync 检查在模式分支前 service:1044-1056,paste 分支不调 assertSourceReadAccess,符合规格)。**

## 2. selected_fields 传播(P2 §2)—— **2 error + 1 minor**

过:加字段 → 镜像列出现(readonly=true)+ 映射行插入;`[]` → 400;`null` → 200 全字段;updateSync 标题/on_delete_action 白名单校验;Syncing/Paused 拒改。

**E3 — 减字段必 500(部分删除后留半态)**
`TableSync.listColumnMappings`(models/TableSync.ts:210-222)`.select('source_column_id','dest_column_id')` **不含 id**;updateSync 减腿 `table-syncs.service.ts:902-904` 按 `m.id` 删映射行 → `Undefined binding(s) detected when compiling DEL. Undefined column(s): [id]`(后端日志实锤)。时序:循环内先 columnDelete(Qty 列删成功)→ knex del(undefined id) 抛 500 → 循环中断:后续列不删、映射行残留、selected_fields 不持久化。半态下后续 null 全字段恢复时 toAdd 判定按残留映射误判「已映射」→ 列不重建。修复:listColumnMappings 补 select `id`(或减腿改按 source_column_id 删)。

**E4 — 加字段后新列数据永不同步**
根因:`columnsService.columnAdd` v2 语义返回 **Model**(columns.service.ts:3854-3861 返回类型 `T extends V3 ? Column : Model`),updateSync 增腿(:911-923)把它当 Column 用:`addedCol.id` = **nc_models.id**,落进 column_mappings.dest_column_id → processor fieldMap `destColById.get(dest_column_id)` 永不命中 → fields 过滤掉新列 → payload 无该键。实测闭环证据:干净样本(SYNC4 初始 ['Title'])→ updateSync 加 Qty 200(列出现 readonly ✓)→ resync updates=3 执行(引擎日志)→ Qty 恒 null(三次 resync 不恢复);源加 row4 走 insert 路径同样 null → fieldMap 断非 update 专属;meta API 可见新列(cache 非 stale);createSync(null 全字段)同列数据正常 → 差异只在增腿映射行。连带:`metaUpdate({readonly:true}, addedCol.id)` 打到 model id = 无效写(nc_columns 无该行),readonly 恰好正确纯靠 columnAdd payload 兜住。修复:columnAdd 返回后按 title 从 `mirrorModel.columns` 取实际列 id。

**minor M1 — resolveLink 密码保护视图无密码时泄露源表/视图标题**
`table-syncs.service.ts:1139-1147`:view.password 存在且未给密码时 passwordProtected:true 但仍返回 sourceTableTitle/sourceViewTitle/sourceBaseId 等。同文件 sourceSchema paste 分支(:289-296)无密码时只返 `{passwordProtected:true}` 不泄露——同批实现两个入口语义不对齐。公开共享视图密码语义 = 无密码不可见内容,标题泄露与之相悖。实测:T1c 断言 `sourceTableTitle=f09p2r1l5_src_tbl` 泄露实锤。建议 resolveLink 对齐 sourceSchema 形状。

## 3. 源列类型漂移传播(P2 §3)—— **过(1 minor)**

干净样本:源 Qty SingleLineText→Number → resync → 镜像 Qty uidt=Number 跟随 ✓;漂移不阻塞数据同步(行数与源一致)✓;反向(Number→SingleLineText)同样跟随 ✓。失败仅 warn:processor :174-178 try/catch per column,代码审确认。
**minor M2 — 漂移传播后当轮数据写入仍按旧类型 cast**:destBaseModel 在漂移循环**之前**构造(processor :125-126 vs :153-179),循环内只改内存 destCol 对象,:170 注释称 "then refresh the dest model meta" 但 baseModel 未重建 → 当轮 upsert cast 仍走旧类型(meta 已变,次轮生效)。实测未观察致错(数值串互转兼容),类型跨度大时(如 Text→JSON)当轮可能类型不符。建议 destBaseModel 重建或移到漂移循环后。

## 4. detach 转正(P2 §4)—— **过**

API:detach 200 → getSync 404、list 空、镜像表保留(数据行数不变)、synced=false、列 readonly 解锁(改列 title 200 + 插行 200)。UI 活体(camoufox session f09p2r1l5,账号 f09p2r1l5-ui):
- 树节点三点菜单展开:`shots/sync-menu-open.png` — Synced table 徽标 / Sync now / Pause sync / **Convert to regular table** / Delete sync 全项活体
- 点 Convert → 菜单即切常规表组(Delete table 出现,Sync 组消失)= synced=false 生效;`shots/after-convert.png`
- 转正表打开:3 records 数据完整、RemoteId/RemoteDeleted 不可见、底部 New record 可用(可编辑);`shots/detached-table-grid.png`
- 后端面:getSync 404 + tables synced:false 双验
Syncing 中 detach → 400:race 窗口难构造(job 秒级完成),代码审确认守卫(service :1164-1166),UI 侧 Convert 项在 Syncing 态未藏(见 M3)。

**minor M3 — Syncing 态树菜单 Convert/Delete 项仍可点**(`SyncMenuOptions.vue:160-169/171-181` 仅 `:disabled="isUpdating"`,未按 `sync.status===Syncing` 藏匿;对照 Sync now 有 v-if 藏匿)。点击会 400 toast,后端守卫在,纯 UX。

## 5. 灰区修复(P2 §5)—— **过**

- resync 复检 allow_sync 关 → 400(paste sync 与 browse sync 双验:service :1044-1049 模式分支前)
- browse 源权限丢失 → 404:api2(src editor)建 sync 后收权 no-access('no-access' 值,PATCH 200)→ resync 404 = baseNotFound(规格值 404 ✓;对照:owner resync 自己的 sync 200)
- paste 不复检 base 权限:resolve 面已证(api2 无源权限 resolve 200);paste resync 面被 E1/E2 阻断(E-blocked)
- createSync 原子性:主动构造失败点不可行(镜像表建后失败路径需 DB 层故障);代码审确认 catch → tableDelete(forceDeleteSyncs) → rethrow(service :720-733),best-effort + 原错误上抛语义正确

## 6. P1 全矩阵回归(P2 §6)—— **过**

- 引擎 e2e:full-create(RemoteId 键控,行数/值对照)、resync upsert(日志 updates=3)、**on_delete_action=delete 策略**(源删 row3 → resync → 镜像 row1,row2,row4;此前一次「未删」系测试脚本 DELETE 路由误用 404 被吞,换 `DELETE /tables/:id/records` + body 后正确)
- ACL:无关用户(f09p2r1l5-ui)对 base 的 list/detach/resync/resolve-link/source-schema 全 403;匿名 list/resolve 全 401;owner 正常
- 付费锁:syncTrigger=realtime 400(API 面未被绕过)
- 守卫链:synced 表 readonly 列(meta API readonly=true)、系统列网格不可见(UI 截图佐证)
- 守卫链 editor 写 400/跨 base 复检的细矩阵 P1 R11 已闭环,本轮抽测通过,未复跑全量

## 7. 质量门

- `tsc --noEmit` exit 0
- jest Fork 桶(全量 testRegex):**3 suites / 41 tests 全过**(含 resync upsert/delete 策略/mark_deleted/paused 跳过/realtime 拒收)
- Vite URL 法:CreateNewSync.vue 200 + SyncMenuOptions.vue 200

## 8. 结论与计数

| # | 级别 | 一句话 | 位置 |
|---|---|---|---|
| E1 | error | paste createSync 缺 sourceTableId 回退 → 前端路径必 400 | table-syncs.service.ts:460-464 |
| E2 | error | paste createSync getColumns 用 dest context → 'no syncable columns' | table-syncs.service.ts:465(vs :297-303 正确样本) |
| E3 | error | 减字段 500:listColumnMappings 无 id,knex undefined binding + 半态 | models/TableSync.ts:210-222 + service:902-904 |
| E4 | error | 增腿 dest_column_id 落 model id(columnAdd 返回 Model 误当 Column)→ 新列数据永不同步 | service:911-923 + columns.service.ts:3854-3861 |
| M1 | minor | resolveLink 无密码泄露源表/视图标题(sourceSchema 已正确对齐) | service:1139-1147 |
| M2 | minor | 漂移传播当轮 baseModel 未重建,写入 cast 用旧类型 | processor:125-126/153-179 |
| M3 | minor | Syncing 态树菜单 Convert/Delete 未藏,可点出 400 | SyncMenuOptions.vue:160-181 |

E-blocked(修复 E1/E2 后需补测):paste sync 的 resync 拉数、paste 不复检 base 权限的 resync 面、paste 建同步后映射 source_uuid/hash 落库断言(代码审:insertMainMapping :757-761 落 uuid+bcrypt hash,明文不落库,映射 API 响应含 hash 与上游 SDK 类型设计一致)。
观察项(不计):paste sync 源视图后设密码时,已建 sync 的持久凭证(uuid)仍有效——resync 未复验 source_password_hash;EE 语义未定,规格未要求。

判定提示:四条 error 全部在 P2 新增代码面(paste createSync / selected_fields 传播),修复面集中且小(E1/E2 各 ~3 行,E3 补 select,E4 取列 id 方式修正);detach/漂移/灰区/回归面质量良好。

## 证据索引

- 截图:/tmp/f09p2r1l5/shots/(paste-create-toast.png = E1 用户可见面;sync-menu-open.png = P2 菜单活体;after-convert.png + detached-table-grid.png = detach 转正)
- 脚本:/tmp/f09p2r1l5/(setup.sh、t1.sh paste 全链、t2.sh 生命周期、t3.sh 漂移/权限)
- 后端 500 日志:/tmp/nocodb-internal.log(:865 Undefined binding DEL)
- 引擎日志:「Table sync tssj3vf5mviuein7e: … updates=3」(E4 佐证)
