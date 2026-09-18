# R8 F09 lane5 报告（UI 验证重点路）

**结论：1 error + 0 minor（另有 3 条观察项，不计数）**

- **E1（error）**：删除流自动跳转双腿失败（R6 修复点 2 主场景回归）——`SyncMenuOptions.vue` 裸解构 `useTablesStore()`，`activeTable.value?.id` 恒 undefined，重定向分支死代码。腿 1（删当前表→跳剩余首表）与腿 2（删至 0 表→跳 base 根）均停死 URL + 空白网格；腿 3（删非当前表→不跳转）通过。判别实验证实为 F09 独立缺陷而非平台行为：同状态删除**普通表**（上游 DlgTableDelete，`storeToRefs` 写法）跳转正常。
- 附录 A / B1 / B3 / B4 / B5 全部通过；附录 C 继承回归全部通过（拒绝向差异均为沿袭已知项方向）。
- 质量门：后端 tsc exit 0 + jest Fork 桶 41/41 + 附录 A Vite URL 全 200。

审查基线：HEAD = 54f36a1f80（= 9c4db33fe1 + chore 记录提交，源码与 R7 修复一致）。服务 :8080/:3000 全程健康（例外见观察项 3 的瞬时 DB 断连，已自愈）。

---

## 附录 A 编译健康先行门 — PASS

1. `GET :3000/_nuxt/components/project/Action/CreateNewSync.vue` → **200**
2. `GET :3000/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` → **200**
3. camoufox 实开 base 页：无 `vite-error-overlay`、无 `[data-nuxt-error]`、无 "error loading dynamically imported module"（eval 三项全 false；截图 `shots/01-dest-base-open.png`、`24-editor-base.png`）。树中 synced 表带 sync 图标正常渲染。

## 附录 B1 创建流树刷新 — PASS（R6 修复点 1 + R7 回归）

- owner（UI 专属账号 `f09r8l5-ui`，ws-creator + dest creator）在 dest base 走完向导三步（step0 选 base/table → step1 fields → step2 标题/策略 → Create sync）。
- **无页面刷新**：创建前后 `window.__f09r8l5_nav_marker` 存活（同一 JS context）。
- **树即时出现** synced 表 `f09r8l5_ui_s1`（eval treeTexts 4 项含之；截图 07）。
- **toast 单一**：MutationObserver 捕获仅 `["Create sync"]` 成功 toast，无 error toast 并存（截图 07 右下角）。
- **API 侧**：`GET /table-syncs` → `f09r8l5_ui_s1 status=active`。
- 备注：测试中误开的 Create Table 残留框为审查脚本所致，非应用缺陷，已关闭。

## 附录 B2 删除流自动跳转 — **1 error（E1）**

前置：`f09r8l5_ui_s1` 为当前打开表（URL `/w9qi3ljd/penbuxw354767lm/m21vgzs7k6n19m4/...`）。

- **腿 1 FAIL**：sync 菜单 Delete sync → 确认后树**即时移除** ✓，但 URL **停在已删表地址**（7.5s 后复查不变），主区空白网格、无 tabs（截图 17）。预期：自动跳剩余首表（dest_local）。
- **腿 2 FAIL**：dest2（仅 1 个 synced 表 `f09r8l5_d2sync`，本地表已删）删除该 synced 表 → 树变 "No tables" ✓，URL 停死在已删表路径，未跳 base 根（截图 21）。
- **腿 3 PASS**：mirror 打开状态下删除非当前表 `f09r8l5_md2_1789700687` → URL 不变（仍 mirror）+ 树即时移除（截图 20）。

**根因定位**（代码对照 + 判别实验）：

```
SyncMenuOptions.vue L26:
  const { baseTables, activeTable, openTable } = useTablesStore()   // 裸解构
  ...
  const oldActiveTableId = activeTable.value?.id   // store 解构出的是已 unwrap 值，
                                                   // .value 恒 undefined → oldActiveTableId 恒 undefined
  if (oldActiveTableId === props.table.id) { ... } // 恒 false → 两条跳转腿死代码
```

上游参照 `dlg/Table/Delete.vue` L23 用 `storeToRefs(useTablesStore())`（ref 语义保留），故普通表删除跳转正常。

**判别实验**：同一页面状态、同一当前表条件下，删除普通表 `f09r8l5_dest_local`（DlgTableDelete 路径）→ URL 正确自动跳到 `f09r8l5_mirror_1789700687`（`.../meln4x39s039c0t/...`）。排除了平台层 activeTable 解析问题，缺陷锁定在 `SyncMenuOptions.vue` 的解构写法。

**定性**：与 R6 修复点 2 的意图直接相悖（该修复就是为让此分支活过来），与 R7 `loadTables` 重声明同族（store 解构/命名类错误，R6/R7 两轮修复各漏一处）。修复建议：`const { baseTables, activeTable } = storeToRefs(useTablesStore())` + `const { openTable } = useTablesStore()`（或全部走 storeToRefs）。

## 附录 B3 树菜单新鲜度 — PASS（R5 M2 回归）

对 `f09r8l5_ui_s1`（不刷新页面）：

1. 初始：菜单显示 `Synced table` + Sync now + Pause sync（截图 12）。
2. Sync now → 菜单自动关 → **重开**：`Synced table`（非 Syncing 卡死）+ Freeze 在位、无 Resume（eval 四态 + 截图 14）。
3. Pause sync（freeze）→ 重开：`Paused` + Sync now + **Resume sync**，Freeze 消失（截图 15）。
4. Resume sync → 重开：`Synced table` + Freeze 恢复、Resume 消失（eval 四态）。

open-watch 每次打开重拉 sync 记录的修复有效，无挂死状态。

## 附录 B4 可搜索选择器 — PASS（R5 M1 回归）

- step0 base 下拉输入 `f09r8l5-src` → 精确过滤为 2 项（`f09r8l5-src-1789699383`、`f09r8l5-src-priv-1789699383`；截图 03）。
- table 下拉输入 `src_tbl` → 可见 dropdown 仅 `f09r8l5_src_tbl` 一项（hidden portal 中的旧 base options 已排除后验证；截图 04）。

## 附录 B5 editor 三入口 fail-closed — PASS

editor（`f09r8l5-editor`，dest base editor）：

1. **Create New 入口**：树内无 Create New 按钮（createNewBtns=0，整体不可见）。
2. **base home「NocoDB Sync」卡片**：editor 打开 base 根 URL 自动落到唯一表，无 Data Actions 卡片渲染面（syncCard=0）。
3. **树 context 菜单 sync 段**：菜单仅显示 TABLE ID + 复制，无 Rename/同步段/删除（截图 26）。
4. **API 面**（同轮 API 套餐）：editor createSync → 403；editor source-schema → 403。无泄漏通道。

## 附录 C 继承回归 — PASS

### C1 E1 六格矩阵（显式 base no-access；给矩阵用户 dest creator 后实测）

| 格 | 用户 | 判定 |
|---|---|---|
| 非私有 + no-access + ws-creator，source-schema | f09r8l5-na-wsc | **404** ✓ |
| 非私有 + no-access + ws-no-access，source-schema | f09r8l5-na-wsn | **404** ✓ |
| 私有 + no-access + ws-creator，source-schema | f09r8l5-na-wsc | **404** ✓ |
| 私有 + no-access + ws-no-access，source-schema | f09r8l5-na-wsn | **404** ✓ |
| 非私有 + no-access → createSync（数据面） | f09r8l5-na-wsc | **404** + 无孤儿镜像表（`f09r8l5_e1_orphan2` 计数 0）✓ |
| 私有 → createSync | f09r8l5-na-wsn | **404** ✓ |

### C2 R6-B 象限（source-schema）

| 象限 | 实测 |
|---|---|
| 非私有 + 零 base 行 + ws-creator（wscreator） | **200** ✓ |
| 非私有 + 显式 editor(src) + creator(dest)（q2） | **200** ✓ |
| 非私有 + inherit + ws-creator（inh2 fresh 用户） | **200** ✓ |
| 私有 + 零 base 行 + ws 可读（wscreator→priv） | **404** ✓ |
| 非私有 + 零关系 + ws no-access（wsno） | 403（fail-closed，见观察项 1） |
| 私有 + inherit + ws no-access（inh-wsc 原始态） | 404（其时该用户 ws=no-access，语义同 Q6 拒绝向）✓ |

### C3 ACL 端点矩阵

- owner：list/get/source-schema/freeze/resume/create → 200；patch/delete 按语义。
- editor：list/get/source-schema/freeze → 403；createSync → 403；resync → 403。
- viewer：同上全 403；anonymous：get sync → 401；wsno（零 base 行）：全 403（fail-closed）。

### C4 引擎 e2e

- full-create：镜像 3 行 + `RemoteId` 全填充 + status=active。
- resync upsert：源 row1 Qty→42 + 新增 row5 → 重同步后镜像 `q42=1`、行数吻合、status=active。
- **delete 策略**：源删 Id 2、4（bulk `DELETE /api/v2/tables/:id/records` body `[{"Id":N}]`）→ resync → 镜像精确剩 row1/3/5。
- **mark_deleted 策略**：sync3 同源 → 源删 row5 → resync → 镜像保留 row5 且 `RemoteDeleted=true`（双策略收敛）。
- freeze → `paused` + resync 400 `"Sync is paused. Resume it before syncing"`；resume → `active`。
- deleteSync → 200 + 镜像表从 base 移除。

### C5 守卫链 + 系统列

- editor 对 synced 表：insert → 400、update → 400、delete → **422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`**（上游语义，沿袭已知项）。
- `RemoteId`/`RemoteDeleted`：DB `system=true` ✓；grid UI 不可见（截图 11 无系统列）✓；UI New record 按钮对 synced 表置灰（引擎管理写禁用）✓。
- 观察项 2（不计缺陷）：v1 table meta 中两系统列 `show=null`（字段级 show 未显式落 false），网格不可见由 `system=true` 保证；与"show=false + system=true 双保险"表述存在偏差，R2 裁定口径如需严格落 show=false 可作 backlog。

## 质量门

- **后端 tsc**：`cd packages/nocodb && npx tsc --noEmit` → **exit 0**（0 错误）。
- **jest Fork 桶**：`npx jest --runInBand --forceExit`（testRegex `Integration|Source|Fork`）→ **3 suites / 41 tests 全 PASS**（362s；table-syncs.Fork.spec 在内）。
- **附录 A Vite URL**：CreateNewSync.vue / SyncMenuOptions.vue 均 200；base 页无 overlay（见附录 A）。
- 说明（观察项 3）：nc-gui 全量 tsc 为上游噪音基线（189 文件 2628 行，F09 三个触达文件 Node.vue/SyncMenuOptions.vue/CreateNewSync.vue **0 错误**）；"tsc 0"质量门仅对后端有意义——与 R7 lane5 记录的「tsc/jest 不编译 .vue」教训一致，前端编译健康以附录 A Vite URL 法为准。

## 观察项（不计 error/minor，供 orchestrator 归档）

1. **拒绝码 403 vs 预期 404**：零关系 ws-no-access 用户（wsno）连 dest 侧 ACL 都不通过（403 "Unauthorized access"，role hydration 对显式 no-access 行用户的处理），未到达 F09 服务层 404 分支。E1 语义（服务层 404）已由 C1 六格单独证实。方向 fail-closed，沿袭已知项「404 vs 平台 403」同族，未升级。
2. **角色置位后进程内缓存滞后**：先以 inherit + ws-no-access 触发 source-schema（BaseUser.get 缓存 joined 行），再 DB 提权 ws-creator → 仍 404；换 fresh 用户（先提权后 invite）即 200。上游缓存行为、fail-closed 方向、非 F09 引入；真实用户流（invite 即最终角色）不受影响。
3. **运行期瞬时 DB 断连**：jest Fork 桶跑完后 ~2 分钟内 :8080 出现 `ERR_DATABASE_OP_FAILED/ECONNREFUSED`（DB 连接层），health 200 但 signin 失败；60s 轮询 ×2 自愈，未干预。并行跑 jest 的 lane 需注意。另：UI 登录会轮转同账号 API token_version（UI/API 测试账号必须分离）。

## 纪律与清理

- 只读审查：未修改任何仓库源码；脚本均在 `/tmp/f09r8l5/`（截图 26 张 `shots/`）。
- 隔离：未读任何其它 lane 报告。
- 未执行 dev-backend*.sh / pkill / 进程操作 / psql 提权；DB 仅 SELECT + 本账号角色置位（等效 invite API，红线允许）。
- 测试数据：5 个测试 base（src / src-priv / dest / dest2 / x）全部删除（200），`f09r8l5-*` base 残留 0；账号按惯例留存。
- camoufox 专属 session `f09r8l5`，已 close。

## 修复建议（供裁决参考）

`packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue` L26：

```ts
// 现：
const { baseTables, activeTable, openTable } = useTablesStore()
// 改（对齐上游 DlgTableDelete）：
const { baseTables, activeTable } = storeToRefs(useTablesStore())
const { openTable } = useTablesStore()
```

修复后须复测：腿 1（删当前打开 synced 表 → 自动跳剩余首表，URL 与主区一致）、腿 2（删至 0 表 → base 根 URL）。回归面：B2 腿 3（不应误跳转）+ B3 菜单新鲜度（storeToRefs 不影响 open-watch）。
