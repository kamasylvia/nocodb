# F09 P2 R2 修复回归 — lane 4(引擎重点路)报告

**结论:PASS**(0 error + 0 minor)

基线 HEAD = 366e0b7045(R1 修复批,五 error 全修)。后端 :8080 = pid 33253(01:24:06 起)晚于 dist mtime(23:39),dist 含 P2/R2 特征(sourceInputMode 4 / sharedViewUrl 5 / resolveLink 6 / bypassSyncedFieldGuard 4 / passwordProtected 7)。R1 五 error(E1/E2/E3/E4/M1)+ M3 菜单守卫逐项活体回归全过;P1 全矩阵回归全过;引擎三重点(增列真实进数 / 类型漂移传播 / paste 引擎拉数路径)全过。账号 f09p2r2l4-*,camoufox session f09p2r2l4(已关),测试 base 三枚已删(200)。

## 0. 源码审(修复批 366e0b7045 diff vs R1 建议逐条对照)

| R1 项 | 修复落点(当前源码) | 判定 |
|---|---|---|
| E1 paste 缺 sourceTableId | service.ts:463-468 srcContext 统一 + `Model.get(srcContext, view.fk_model_id)`(不再依赖入参 sourceTableId) | ✓ |
| E2 getColumns 用 dest context | service.ts:469 `srcModel.getColumns(srcContext)` | ✓ |
| E3 减腿 500 undefined binding | service.ts:904-909 delete 改按 `(fk_table_sync_id, source_column_id)` 键 | ✓ |
| E4 增腿 dest_column_id 落 model id | service.ts:930-937 `addedModel.columns.find(c=>c.title===srcCol.title)` + 取不到 fail-fast;readonly 强制/metaUpdate 均用真实 col id | ✓ |
| M1 resolveLink 泄露标题 | service.ts:1138-1140 无密码 `return { passwordProtected: true }`(与 sourceSchema paste 分支同形) | ✓ |
| M3 Syncing 态菜单可点 | SyncMenuOptions.vue Convert/Delete 两项均加 `v-if="sync.status !== TableSyncStatus.Syncing"` | ✓ |

## 1. E1+E2 paste 建同步(活体,对齐前端形态)

- `POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>}`(**不带 sourceTableId**,CreateNewSync.vue 实发形态)→ **200**(R1 双 400 症状零复现)→ status Syncing→active(1s)
- 引擎拉数:镜像 3 行 row1/2/3(Qty/Note 全对齐,RemoteId=1/2/3);镜像列 readonly=true ×3 + RemoteId/RemoteDeleted system
- mapping(main):source_uuid = 视图 uuid 落库 ✓;明文密码 0 泄露
- **E-blocked 补测(R1 因 E1/E2 阻断)**:源加 row4 → api2(**无源 base 权限**)resync → 200 → 镜像 4 行(row4 进数)——paste 凭持久 uuid 凭证的 resync 拉数路径成立
- 密码三态:设密后 无密码 400「password protected」/ 错密码 400 / 对密码 200 → 第二个 paste sync active + 4 行;其 mapping source_uuid ✓ + **source_password_hash 落 bcrypt($2 开头)**,明文 0 泄露 ✓

## 2. E3+E4 selected_fields(D2 browse sync,初始 [Title,Qty],活体)

- **E3 减腿**:PATCH `{"selected_fields":["Title"]}` → **200**(R1 500 Undefined binding 零复现)→ 镜像 Qty 列删 + resync 后数据对齐;无半态(后续增腿正常,证明映射行确实删净——若残留,增腿按 mappedSrcIds 会误判已映射不重建列)
- **E4 增腿(本轮引擎头牌)**:PATCH `["Title","Qty"]` → 200 → Qty 列重现 readonly=true → resync → **Qty 数据真实进数:1/2/3/4 四行全进**(R1 症状 = 恒 null,机理为 dest_column_id 落 model id 致 processor fieldMap 永不命中——本轮进数即 dest_column_id 正确的最强活体;column mappings 无公开 API 端点,getSync.mappings 仅含 main 行,故以引擎行为代直查)
- **update 路径**:源 row1 Qty→100 → resync → 镜像 100(新列在 update 通道同样进数)
- `[]` → 400 ✓;`null` → 200 全字段(Note 列现 + n1-n4 进数)✓

## 3. 源列类型漂移传播(引擎重点,活体)

- SingleLineText→LongText:resync 后镜像 Note uidt=LongText 跟随,4 行数据完好
- 反向 LongText→SingleLineText + **同轮**源值变更(n3→长文本):镜像跟随 + 新值当轮进数完整
- M2(R1 观察项:漂移当轮 destBaseModel 未重建)impl 未改;本轮兼容类型场景实测无错,维持观察项定位,不计缺陷

## 4. M1 resolveLink 密码保护(活体)

- 设密视图 无密码 resolve → 200 `{"passwordProtected":true}` —— sourceTableTitle/sourceViewTitle/sourceBaseId **零泄露**(R1 泄露实锤点已闭合)
- 对密码 → 全量坐标(sourceInputMode/sourceBaseId/sourceTableId/sourceViewId/双 title/passwordProtected:false)✓;错密码 → 400 ✓

## 5. M3 菜单守卫(camoufox 活体,session f09p2r2l4)

- active 态树菜单全项可见(截图 r2-menu-active.png):Synced table 徽标 / Sync now / Pause sync / Convert to regular table / Delete sync
- **Syncing 态竞速捕获**:点 Sync now 后 DOM 轮询(100ms 步)记录——`t=204-307ms: status="Syncing" 且 table-sync-menu-convert=false、table-sync-menu-delete=false`(两 testid 从 DOM 消失,v-if 生效);t=409ms job 完成(Synced table)后两项目恢复。窗口 <200ms 截图不可行,轮询数据为证
- 后端守卫(Syncing 中 detach/update/delete 400)R1 已验,本轮未变

## 6. P1 全矩阵回归(活体,全过)

- 删除策略:**on_delete_action=delete**(源删 row4 → resync → 镜像 3 行)+ **mark_deleted**(PATCH 200 → 源删 row3 → 行保留 RemoteDeleted=true)
- freeze/resume:freeze 200 → paused 下 resync 400 → resume 200
- 付费锁:syncTrigger=realtime 建同步 400「Only the manual sync trigger is supported」
- 守卫链:镜像 insert 400(synced 只读);Qty readonly=true
- ACL:editor 对 D2 resync/detach 403、对 D1 resync 403;匿名 list/resolve-link 401
- 生命周期:detach paste sync 200 → getSync 404;deleteSync 200 → getSync 404

## 7. 质量门

- `tsc --noEmit`:exit 0
- jest Fork 桶:3 suites / **41 tests 全过**(149s)
- Vite URL 法:SyncMenuOptions.vue 200 + CreateNewSync.vue 200

## 8. 测试资产与清理

- 脚本:/tmp/f09p2r2l4/(setup.sh、t1.sh、t1b.sh、t2.sh、t3.sh、t3b.sh、t6.sh;env.sh 含一次性测试账号口令,未入 git)
- 截图:/tmp/f09p2r2l4/shots/r2-menu-active.png(active 态全项)、r2-final-state.png
- 资源:base f09p2r2l4_src/d1/d2 三枚 DELETE 200(camoufox 关闭后执行,数据面经 API 断言留痕本报告);账号 f09p2r2l4-{api,api2,ui,e}@ce-ee.local 留存(与 R1 惯例一致,f01e2e 仅作建 base/邀请搭桥)
- 基线副作用:零(全程只读源码,未构建/未重启/未跑 dev-backend*.sh)

## 9. 备注

- column mappings(TABLE_SYNC_COLUMN_MAPPINGS)无公开 GET 端点,E3/E4 的映射行直查不可行;以「减列后重建增列成功 + 引擎进数」闭环替代(机理:E4 bug 形态下 fieldMap 必不命中 → 恒 null;进数 = dest_column_id 必为真实列 id)
- 观察(不计):getSync.mappings 不含 column mapping 行,前端若需展示映射明细需另寻端点——P2 规格未要求,仅记录
