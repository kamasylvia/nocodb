# F09 P1 Table Sync — R5 lane2 复审报告(lane 2,重派批)

issues(1 error + 2 minor + 3 observations)

- HEAD:f81e24a4f4(F09 R5 修复批:rewrite assertSourceReadAccess)
- 测试前缀:f09r5l2b-*(owner 载体 = 任务书指定 f01e2e@ce-ee.local);camoufox --session f09r5l2b
- 环境::8080 全程健康未动;:3000 Nuxt dev 正常;测试 base 已全删(4/4 HTTP 200)

## E1(error)— assertSourceReadAccess 漏"显式 no-access base 行"象限,源数据泄露

- 位置:`packages/nocodb/src/services/table-syncs.service.ts` assertSourceReadAccess(non-private fall-through 分支)
- 现象:用户在源 base(nc_base_users_v2)有**显式 roles='no-access'** 行、同时持有效 workspace 角色(实测 workspace-level-viewer)、base 非私有:
  - 平台 ground truth:`GET /api/v2/meta/bases/:srcId` → **403 Forbidden**(listing 谓词亦隐藏:Path1 被 NO_ACCESS 排除,Path2 要求 base roles NULL/INHERIT,no-access 不满足)
  - fork F09:`POST .../table-syncs/source-schema` → **200**(schema 全量返回);`POST .../table-syncs`(createSync)→ **200 且引擎实际拉走源表 3 行数据落镜像表**(实测记录,已清理)
- 根因:重写把 `hasExplicitBaseRole=false`('no-access' 被排除)的用户直接放进 non-private fall-through(`!hasExplicitBaseRole && !hasWsRead` 才拒),未区分「base 行 roles 为 NULL/inherit(可 fall-through)」与「base 行显式 no-access(平台两路皆断,必须拒)」。commit 声明 "mirror the platform predicate exactly"(BaseUser.ts:563-631),该象限未镜像。
- 建议:fall-through 仅当 base 行 roles ∈ {NULL, '', 'inherit'};显式 no-access 行无论 ws 角色一律 `NcError.baseNotFound`。修复面约 3-5 行 + 矩阵补 1 象限。
- 证据:矩阵行 `bnoa(base-noacc+ws-viewer):PUB:GET 403 / PUB:SCH 200`;createSync syncId tssh97clfvoq7wucr(镜像 3 行 row1-3,已删)。

## 复审通过项(8 项清单)

1. **diff 审查**:assertSourceReadAccess 重写语义四象限正确(见下矩阵);jobs-map [CE-EE] ×3 在位(import/constructor/jobMap);console.debug 残留 0;store/sync.ts、syncUtils.ts、acl.ts、ncUtils.ts 全链零 F09 触碰(仅上游 commit);isSyncFeatureEnabled=ref(false) 恒定;blockTableSync=false、blockTableSyncAuto/blockCustomSync=true。
2. **ACL 矩阵**(10 用户 × pub/priv,source-schema vs 平台 GET base):ws-creator 200/404 ✓ 镜像;ws-no-access 404/404 ✓;base-creator(ws-no-access)200 ✓(R5 修复点 1:不再 404 死路);priv-creator 200 ✓(R5 修复点 2);inherit+ws-editor 200/404 ✓;dest-only(ws-no-access,零 base 关系)404 ✓(R4 回归不破);全零关系 403(dest ACL 先拒)✓;dest-editor 十端点 403(creator+)✓;owner 200 ✓。E1 象限除外。
3. **引擎 e2e**:full-create 3 行镜像、RemoteId 与源 Id 1:1;源 PATCH Qty=22 → resync → 镜像 22(upsert 全字段刷);源删行 → delete 策略 → 镜像删行;切 mark_deleted → 删行 → RemoteDeleted=true 行保留;freeze → resync 400 → resume → active;deleteSync → GET 404。注:首轮 §3/4/9 异常复测证实为测试脚本 v2 records API 形态误用(单行 PATCH/DELETE 路由不存在),非产品问题。
4. **守卫链 + 系统列**:insert synced 表 400、delete synced 表 400、realtime createSync 400(付费锁保持)、selected_fields 变更 400、on_delete_action 更新 200;RemoteId/RemoteDeleted 网格**不可见**(UI 截图,仅 Title/Qty)且 "New record" 灰置只读;fields API hidden=null 与其它系统列一致,隐藏由 system:true + 前端 SYNC_SYSTEM_COLUMN_TITLES 保证。
5. **UI 段**(camoufox f09r5l2b,截图 12 张于 /tmp/f09r5l2b/shots/):Overview「NocoDB Sync」卡 creator 可见 / editor 不可见;向导三步 Back/Next/Create **在 body 渲染可用**(base 下拉为虚拟滚动,a11y 树仅暴露前 2 项为测试装置限制,截图证实完整列表),Create 后 dest 新增 active sync;树上 synced 表带 sync 图标;节点菜单 Synced table/Sync now/Pause sync/Delete sync 全渲染,**Sync now 实操生效**(Syncing→active)、**Pause 实操生效**(paused)、**Resume 实操生效**(active)、**Delete 确认弹窗实操生效**(GET 404);editor 三入口全隔离(Overview 卡无、树菜单无 sync 项、Share 弹窗无 Allow sync);源侧 Share 弹窗 Allow sync 渲染 ON 且无 paywall badge。
6. **回归**:F04 syncs list / F05 variables / F07 snapshots / F08 base get(私有)/ F10 dashboards / F02 permissions / F03 base users 全 200;AirtableImport(F04 legacy 面)不回归。
7. **质量门**:`npx tsc --noEmit` exit 0;jest 3 suites **41/41 passed** exit 0。

## minor

- m1:`packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue` — 菜单 overlay 仅首次 mount 时 load();syncNow 后重开菜单 status 冻结在 "Syncing",Pause/Resume 项维持禁用形态(此时 API 已 active),刷新页面才恢复。建议:监听 dropdown visible 变化重跑 load()。
- m2:`SyncMenuOptions.vue onDelete` — Delete 确认后 sync 行已删(GET 404)且 loadTables() 已调,但树上该表与当前打开的表视图**未即时消失/跳转**,刷新页面后才收敛。建议:remove 成功后强制树刷新 + 路由离开已删表。

## observations(不计 error/minor)

- obs1:editor 打开 base 根 URL(#/nc/:baseId/base)toast "Table 'base' not found"——上游路由在编辑者视角找不到默认表的既有噪声,非 F09 引入。
- obs2:fork 对 ws-no-access 用户 source-schema 返 404(baseNotFound)而平台 baseGet 返 403——隐藏 vs 明拒语义差,fork 方向更保守,不构成泄露。
- obs3:测试装置限制:console error 无法回溯收集(camoufox 无 console 历史),Nuxt overlay 全程未出现(页面无 fatal);UI 菜单点击依赖 DOM 事件注入(antdv Dropdown 对合成事件部分吞掉),Sync now/Pause/Resume/Delete 均经真实点击通道验证生效。

## 纪律遵守

只读审查(未改任何源码);未触碰 dev-backend*.sh / pkill / 后端进程;未用 psql;账号与数据全 f09r5l2b 前缀(4 base 已删,账号留存与历轮惯例一致);f01e2e 载体 token 多次被并行 lane 互踢,均重签到流程内。
