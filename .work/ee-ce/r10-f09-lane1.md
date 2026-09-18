# F09 R10 Lane 1 审查报告

**结论：PASS（0 error + 0 minor）**

- 审查员：f09r10l1 ｜ session：f09r10l1（+ 隔离 ed 会话 f09r10l1ed）｜ 基线：HEAD = 70a78bd4eb（代码面同 5e3d736b2a：`git diff 5e3d736b2a..HEAD -- . ':!.work'` 仅 `.work/` 记录文件，源码零改动）
- 后端 :8080 / 前端 :3000 全程健康（首查 200，无轮询需要；未触碰 dev-backend*.sh / pkill / 进程）
- 测试数据全 `f09r10l1-` 前缀；4 个测试 base（src/dest/priv/zero）测完经 super DELETE，residual: NONE；UI 与 API 账号分离（token_version 互踢见方法学注记 G1）
- 截图：`/tmp/f09r10l1/01-after-create-tree.png、02-ui-sync-grid.png、03-sync-menu-active.png、04-sync-menu-paused.png、05-leg1-after-delete.png、06-leg3-no-jump.png、07-leg2-zero-url.png、08-editor-node-menu.png、09-control-delete-jump.png`

---

## A. 编译健康先行门 — PASS

- `GET /_nuxt/.../SyncMenuOptions.vue` → 200；`GET /_nuxt/.../CreateNewSync.vue` → 200；base 页 `vite-error-overlay` 全程 false（含 :3000/w9qi3ljd、dest 根、两次 grid 深链）

## B. 删除流自动跳转三腿 + 判别对照（camoufox 活体）— PASS

静态先行：`SyncMenuOptions.vue:30-32` = `storeToRefs` 解构 state + actions 裸解构，与上游 `dlg/Table/Delete.vue:23-24` 同模式；`onDelete` 先捕获 `oldActiveTableId` 再 remove（R9 重点修复保持）。

- **腿 1（剩余表）**：打开 ui-sync grid，树菜单 Delete sync → 确认。删除前 `…/mwg32lbf7j1rjjt/vwno7hxjdbty3fys/f09r10l1-ui-sync-…` → 删除后 `…/m86n7rfuccpa3tm/vwicd0u024km65j1/f09r10l1-sync-f09r10l1-sync`，title = `f09r10l1-sync | f09r10l1-sync | f09r10l1-dest`（URL=主区=剩余首表，无空白网格）；树即时只剩 sync/sync-md（截图 05）
- **腿 3（非当前表）**：停留在 sync grid 删 leg3（API 预建）。删除前后 URL 同为 sync grid（**不跳转**），树即时移除 leg3（截图 06）
- **腿 2（base 根）**：zero base（普通 init 表已删，仅剩 synced leg2）打开 leg2 grid 后 Delete sync → URL 归一 `/nc/pnhcvpck3mss80b`（base 根，无 stale table 路径）；树 0 表；主区空状态页（Create New Table / NocoDB Sync 卡正常，截图 07）
- **判别对照**（DlgTableDelete 路径）：普通表 `f09r10l1-ctrl` 菜单仅 `Delete table`（无 sync 项）→ 确认后跳剩余首表 sync grid，树即时移除。与腿 1 语义一致（截图 09）

## C. 创建流 / 菜单新鲜度 / 可搜索选择器 — PASS

- **创建流树刷新**：向导 Browse → base f09r10l1-src-priv → table → Fields(all) → Sync settings → Create sync；关闭后**不刷新**树即时出现 `nc-tbl-side-node-f09r10l1-ui-sync`；notification/alert 类 toast 零条；无错误 toast（截图 01）
- **可搜索选择器**：base 下拉 search input 输入 `priv` → 选项 2→1，命中项 title=`f09r10l1-src-priv`（aria option 名即 label，过滤按 label 生效）；table 下拉出现源表后 Next 由 disabled 转 enabled
- **菜单新鲜度（三态翻转，无刷新）**：开菜单 `Synced table + Pause sync`（截图 03）→ Pause → 重开 `Paused + Resume sync`（截图 04）→ Resume → 重开 `Synced table + Pause sync`。`open` prop watch 重拉生效，无 Syncing 卡死
- **editor 三入口 fail-closed**：① Overview 无 NocoDB Sync 卡（`hasSyncCard=false`）；② synced 表菜单仅 `TABLE ID` 复制项，Sync now/Pause/Resume/Delete 全缺（截图 08）；③ 抽屉 tab 仅 Data/Details/Share/Fields（无 Syncs）。API 侧 editor source-schema/create 均 403

## D. E1 六格 + R5 四象限 + 零关系 — PASS（12/12）

矩阵账号全部 dest-creator 提权（到服务层，符合方法学 B.2）；角色变更经 API（invite/PATCH）触发缓存失效。

| 格 | 组合 | F09 | 平台 GET base | 判定 |
|---|---|---|---|---|
| m1 | 非私有+no-access+ws-creator | 404 | 403 | PASS（fail-closed） |
| m2 | 非私有+no-access+ws-no-access | 404 | 403 | PASS |
| m3 | 私有+no-access+ws-creator | 404 | 404 | PASS |
| m4 | 私有+no-access+ws-no-access | 404 | 404 | PASS |
| m5 | 非私有+no-access→createSync | 404 | — | PASS（dest 无 m5 镜像表，数据面 0 落库） |
| q1 | 非私有+零行+ws-creator | 200 | — | PASS |
| q2 | 非私有+editor+ws-no-access | 200 | — | PASS |
| q3 | 非私有+零关系+ws-no-access | 404 | — | PASS |
| q4 | 非私有+inherit+ws-creator | 200 | — | PASS |
| q5 | 私有+零行+ws-creator | 404 | — | PASS |
| q6 | 私有+inherit+ws-no-access | 404 | — | PASS |
| rel2 | 真零关系（src/dst/ws 均无行） | 403 | — | PASS（dest ACL 先拦，B.1 双码均过） |

## E. ACL 十端点 — PASS

owner：list/get/source-schema/create/update = 200；resolve-link = 501（沿袭）；realtime create = 400（付费锁）。editor/viewer：list/source-schema/create/get/update/resync/freeze/resume/delete = 403。匿名：list/source-schema = 401。

## F. 引擎 e2e + 守卫链 + 系统列 — PASS

- full-create → active；镜像 3 行 = 源 3 行，RemoteId='1'/'2'/'3'；源 +row4 / row1 Qty→100 → resync 后 4 行且 row1 Qty=100（upsert 双分支）
- delete 策略：源删 row4 → resync 回 3 行；mark_deleted 策略：源删 row2 → 镜像保留且 `RemoteDeleted=True`（3 行 flags False/False/True）
- freeze → paused；paused resync → 400；resume → active
- 守卫：editor insert synced 表 → 400；editor PATCH 镜像行 → 400；editor DELETE 镜像表 → 403（R9-lane4 记 404，同 fail-closed 方向，码差不升级）
- 系统列：table meta `RemoteId/RemoteDeleted: system=true`；grid-columns `show=false` 双保险；网格 DOM 叶文本无 RemoteId/RemoteDeleted 字样（注：grid 为 canvas 渲染，DOM 侧为辅助证据，主证据为 show=false 元数据）

## G. 方法学注记（非发现）

1. **token_version 互踢**：同一账号浏览器登录会踢掉 API token（反之亦然）。本轮 API 侧用独立 `f09r10l1-{own,ed,vw}-api` 账号，UI 侧 `f09r10l1-ui-own/ui-ed`；互踢发生后 resignin 取新 token，旧 token 即 401——脚本 401 首先重登，不判服务故障
2. **camoufox session 共享 auth profile**：`f09r10l1ed` 登录 editor 后主会话被踢到 /signin（同机 profile 级共享，非产品缺陷）。editor 证据在 ed 会话内闭环，主会话随后重登继续
3. v2 records 单行 PATCH/DELETE 为 body 式（`/records` + body），全程遵守，无假阳性
4. `GET /api/v2/meta/tables/:id/columns`（无尾斜杠）404——正确路由是 `/columns/`（controller 注册带尾斜杠）或 table meta 内嵌 `columns`；系测试者路径误用，非产品问题

## H. 质量门

| 门 | 结果 |
|---|---|
| 后端 tsc --noEmit | exit 0（195s） |
| jest Fork 桶 | **41/41 passed**（3 suites，含 table-syncs.Fork 15/15；126s） |
| Vite URL 双 200 + overlay 双零 | PASS（A 段） |

## I. 沿袭已知项（均未升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒、FAILED 泛型、resolve-link 501、realtime 400、editor 删镜像行 422、paused 菜单 Sync now 400、深链树骨架、source-schema 对无 allow_sync 视图仍 200（create 侧强制）。
