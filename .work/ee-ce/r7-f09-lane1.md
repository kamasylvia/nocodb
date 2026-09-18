# F09 R7 复审报告 — lane 1（独立审查）

> 基线 HEAD = 5a11c4ab86（R6 修复批）。后端 :8080 无改动；前端 :3000 Nuxt dev HMR 即当前源码。
> 方法：只读代码复审 + 独立 API 集成测试（curl，非 super 账号）+ camoufox 专属 session `f09r7l1` UI 实测。测试数据 `f09r7l1-` 前缀；14 个测试 base 已全删（逐个 DELETE 200）；测试账号留存（dev 惯例）。

## 结论：1 error（其余全过；UI 段被 E-1 连带阻塞，质量门部分未完成）

| # | 级别 | 位置 | 问题 |
|---|---|---|---|
| E-1 | **error** | `packages/nc-gui/components/project/Action/CreateNewSync.vue:18 + :76` | R6 修复 A 引入重复声明：`:18 const { loadTables } = useBase()` 与 `:76 const loadTables = async (baseId)` 同名 → 模块编译失败 → **整个 base 页 (`/nc/:baseId`) 加载崩**（详见证据）。比 R6 E-1 更重：原来只是 toast+树不刷新，现在整页死 |
| B | — | `SyncMenuOptions.vue:60/70` | R6 修复 B 代码在位且逻辑正确（oldActiveTableId 先捕获，DlgTableDelete 同款）；但 UI 实测被 E-1 整页崩连带阻塞，未能活体验证 |

## 逐项证据

### R7-A 创建流（E-1）— ERROR
- 源码：`:18 const { loadTables } = useBase()`（R6 新增）vs `:76 const loadTables = async (baseId: string)`（原向导内按 base 拉表函数，`:159 watch(selectedBaseId) → loadTables(id)` 依赖它）。同作用域 `const` 重名 = 非法。
- 编译证据（esbuild，对 SFC script 节）：`The symbol "loadTables" has already been declared ... :76:6`。注意 `:138 await loadTables()` 现在语义也错——即使重命名其中之一，也必须确认 create 路调的是 **useBase store 的无参版**（正确目标），而 watch 调的是**带 baseId 的 wizard 版**；直接改名不区分会调错函数。建议：store 版改名 `loadBaseTables`（或 wizard 内函数改名 `loadSourceTables`），`:138` 绑定 store 版。
- 活体证据（session f09r7l1，`GET /nc/<uidest>`）：`document.body.innerText` = `error loading dynamically imported module: .../_nuxt/components/project/Action/CreateNewSync.vue ... / Go back home`，bodyLen=245，reload 后复现。base 页因该动态 import 失败整页 error boundary，无树、无向导、无菜单——R7-A/B 的 UI 验证全部被此阻塞。
- API 侧 createSync 本身正常（本轮引擎 e2e 新建 sync 200 + 镜像落地），缺陷纯前端。

### R7-B 删除流 — 代码 PASS，UI 未能验证（被 E-1 阻塞）
- `SyncMenuOptions.vue:60 const oldActiveTableId = activeTable.value?.id` 先于 `remove()` 捕获；`:69 await loadTables()`（useBase store 版，R5 已修）；`:70 if (oldActiveTableId === props.table.id)` + 剩余首表 `openTable` / 0 表回 base 根。顺序与 DlgTableDelete 同构，静态正确。
- 三腿（剩余表跳转 / base 根 / 非当前表不跳转）原需 UI 活体，因整页崩未执行，不记 PASS 也不记 FAIL，下轮 E-1 修后重验。

### R6-A E1 六格矩阵 — 10/10 PASS（含方法修正说明）
- 初跑 6 FAIL 系测试夹具 artifact：共用 DEST0 且 a2/x1/b2 无 dest 读权限 → dest 侧 ACL 403 掩盖 source 检查（body `ERR_FORBIDDEN` 即 dest 门控先拒）。改每用户独立 dest + 显式 grant creator 后：
- 非私有+显式 no-access+ws-creator (a1)：schema 404，平台 GET base 403；ws-noaccess (a2)：schema 404，平台 403。
- 私有+显式 no-access+ws-creator (a3)/ws-noaccess (a4)：schema 404，平台 404。
- a1 createSync 404 且 dest 表数不变（0→0，数据面零镜像）。

### R6-B 四象限重跑 — 6/6 PASS
- 非私有+零行+ws-creator (b1) 200；显式 editor+ws-noaccess (b2) 200；零关系+ws-noaccess (x1) 404；inherit+ws-creator (owner) 200（body view.allow_sync=true, columns=2）；私有+零行+ws 可读 404；私有+inherit+ws-noaccess 404。

### ACL 十端点 — PASS（附状态机时序注记）
- owner：list/get/schema/create/update 200，resolve-link 501；freeze/resume 400 系本轮脚本内先发 create+delete 改变了 SID 状态（时序 artifact，引擎段独立验 freeze→paused→resync 400→resume→active 正常）。
- editor/viewer/零关系 (x1)：十端点全 403；匿名 GET×2 401。无泄露。

### 引擎 e2e — PASS
- full-create：镜像 `1:row1:1:false, 2:row2:2:false, 3:row3:3:false`；synced=true。
- resync：源改 row1→row1b/11 + 增 row4 → 镜像 `1:row1b:11, 2:row2:2, 3:row3:3, 4:row4:4`。
- freeze→paused→resync 400→resume→active；realtime 触发 400；selected_fields 变更 400；resolve-link 501；delete→GET 404。

### 守卫链 + 系统列 — PASS
- owner insert synced 表 400；editor insert 400；editor 删镜像行 422（D 沿袭：上游 ERR_SYNC_TABLE_OPERATION_PROHIBITED 语义，非缺陷）。
- 表 get 列：RemoteId/RemoteDeleted system=true readonly=true；Title/Qty readonly=true；Id/CreatedAt 等平台列不受影响。

### 回归探针 — 6/6 PASS（路由纠偏注记）
- permissions 200 / variables 200（正确路由 `/variables`，初探 `/base-variables` 404 系我侧路径错）/ snapshots 200 / dashboards 200（per-base 路由；workspace 级路由 404 系我侧路径错）/ legacy syncs 200 / 镜像表 records 读 200。

### diff 审查 — PASS
- `git show 5a11c4ab86 --stat` 仅 2 文件（CreateNewSync.vue / SyncMenuOptions.vue）；`aabe3587fe..HEAD` 在 packages/nocodb、store、utils、composables 零 diff；后端/ACL/引擎/jobs-map 均未动。store/sync.ts `isSyncFeatureEnabled` 未动（R6 报告已证恒 false，本轮 backend 零 diff 继承）。

### D 沿袭项 — 未升级，不计
- selectedFields:[]、非原子孤儿表、resync 不复检、404 vs 403、legacy 下划线多拒、FAILED 泛型、resolve-link 501、realtime 400、paused 菜单 Sync now 点 400 fail-closed、深链骨架——均维持 R6 状态。

## 质量门
- 后端 `tsc --noEmit`：后台跑超时（180s+ 未出结果，日志空）→ **未完成**，下轮/裁决重跑。
- jest Fork 桶：`npx jest --testPathPattern "Fork"` 280s 超时零输出 → **未完成**（非 FAIL，跑者超时）。
- 前端 vue-tsc：100s 超时（grep 无 CreateNewSync 命中输出，inconclusive）；esbuild 重名证据确凿，不依赖 vue-tsc。
- :8080/3000 全程 200（首查），无 E3（后端零异常，无需轮询记次）。

## 附注
- token 轮换：lane 账号并行 signin 触发 token_version 轮换致 401 两次，重 signin 即复（dev 环境行为，非缺陷；R6 lane1 同记）。
- base/users 列表形 `{"users":{"list":[...]}}`；ws users 形 `{"list":[...]}`；base 邀请 body `{"email","roles"}` + PATCH 改角色需 org 用户 id（`GET /api/v1/users?pageSize`）。
- UI 会话 f09r7l1 保持打开（页停 error 态供复现）；截图未留（文本证据已足：body innerText 全引用）。
- 脚本：/tmp/f09r7l1-matrix.sh（初版，dest-ACL 缺陷版）/ /tmp/f09r7l1-matrix2.sh / /tmp/f09r7l1-setup.sh / /tmp/f09r7l1-invite.sh / /tmp/f09r7l1-sfc-script.mjs（esbuild 输入）。

## 修复建议（供裁决）
- E-1：将 `:18` store 解构改名（`const { loadTables: reloadBaseTables } = useBase()`）并改 `:138` 为 `await reloadBaseTables()`；`:76` wizard 版与 `:159` 保持不动。单行区改名，不碰逻辑。一行修完后重验：base 页正常渲染 + 向导 create 不刷新出树 + 删除双腿。
