# F09 R11 Lane 1 审查报告

**结论：PASS（0 error + 0 minor）—— R11 连击 3/3 达成，F09 P1 可 pass**

- 审查员：f09r11l1｜session：f09r11l1（+ 隔离 ed 会话 f09r11l1ed）｜基线：HEAD = 71dd2692b1，`git diff 5bea0c3943..HEAD -- . ':!.work'` 为空（仅 `.work/` 记录文件，源码零改动，R10 同规格）
- 后端 :8080 / 前端 :3000 全程健康（首查 200，tsc/jest 期间抽查 200；未触碰 dev-backend*.sh / pkill / 进程）
- 测试数据全 `f09r11l1-`（rerun 批 `f09r11l1b-`）前缀；3 个测试 base（src/dest/zero）测完经 API DELETE 200/200/200，residual: NONE；UI 与 API 账号分离（toks.json 独立，互踢见注记）
- 脚本：`/tmp/f09r11l1/e2e1b.sh`（修正版 rerun）、`e2e2r/br/cr.sh`、`vars2.env`、`e2e*.log`；截图：`/tmp/f09r11l1/01-wizard-open.png、01-after-create-tree.png、02-ui-sync-grid.png、03-sync-menu-active.png、04-sync-menu-paused.png、05-leg1-after-delete.png、06-leg3-no-jump.png、07-leg2-zero-url.png、08-editor-node-menu.png、09-control-before.png`

---

## A. 编译健康先行门 — PASS

- `GET /_nuxt/.../SyncMenuOptions.vue` → 200；`GET /_nuxt/.../CreateNewSync.vue` → 200
- 全程 `vite-error-overlay` false（signin、dest 根、grid 深链 ×3、zero base、editor 会话）

## B. 删除流自动跳转三腿 + 判别对照（camoufox 活体）— PASS

- **腿 1（剩余表）**：打开 UI 新建 synced 表 grid（`…/muc6ugpyq1pr6nj/…/f09r11l1b_src-…`）→ Delete sync 确认 → 跳 `…/m9fo4u7490f11la/…/f09r11l1b_seed-…`，title = `f09r11l1b_seed | … | …-dest`（URL=主区=剩余首表）；树即时 `seed|sync-mark`（截图 05）
- **腿 3（非当前表）**：停留 seed grid 删 API 预建 leg3 → URL 保持 seed 不变（**不跳转**），树即时移除 leg3（截图 06）
- **腿 2（base 根）**：zero base（仅 leg2 synced 表）打开 grid 后 Delete sync → URL 归一 `/nc/p10cjs939twq5yc`（base 根，无 stale table 路径）；树 `ZERO-TABLES`；主区 `No tables` 空状态（截图 07）
- **判别对照**（DlgTableDelete 路径）：普通 seed 表菜单仅 `Rename|Change icon|Duplicate|Edit description|Edit permissions|Delete table`（无 sync 项），与腿 1 语义一致（截图 09 为删前态；未执行删除，base 经 API 清理）

## C. 创建流 / 菜单新鲜度 / 可搜索选择器 — PASS

- **创建流树刷新**：Overview `NocoDB Sync` 卡（testid `proj-view-btn__create-new-sync`，注记 C1）→ 向导 step0 base 下拉 → step1 View + `All fields are synced by default` → settings（Deleted 策略 checked）→ Create sync；关闭后**不刷新**树即时出现第 3 节点 `nc-tbl-side-node-f09r11l1b_src`；notification/message 类 toast 0 条；API 侧新 sync `tsstbxrxncsumb9dc/active`（截图 01）
- **可搜索选择器**：combobox 输入 `f09r11l1b` → 选项收敛到 1（`f09r11l1b-src-1789729939`，label 匹配）；table 下拉选中源表后 Next 由 disabled 转 enabled
- **菜单新鲜度（三态翻转，无刷新）**：`Sync now|Pause sync|Delete sync`（截图 03）→ Pause → `Sync now|Resume sync|Delete sync`（截图 04）→ Resume → 恢复 Pause 三元组。`open` prop watch 重拉生效
- **editor 三入口 fail-closed**：① Overview 可见短串无 `NocoDB Sync` 卡；② synced 表菜单仅 `TABLE ID: mlcbdeliu4fo1bg` 复制项（截图 08）；③ Manage Syncs 系 F04 面板（legacy SyncSource，非 F09 通道）。API 侧 editor source-schema/create 均 403（D 段）

## D. E1 六格 + R5 四象限 + 零关系 — PASS（12/12，脚本序列假象已消核见注记 D1–D3）

矩阵账号全部 dest-creator 提权；角色变更经 API（invite/PATCH）失效缓存；ws 切换有效性以后端回显 `roles` 字段为准（注记 D1）。

| 格 | 组合 | F09 | 平台 GET base | 判定 |
|---|---|---|---|---|
| m1 | 非私有+no-access+ws-creator | 404 | 403 | PASS（fail-closed） |
| m2 | 非私有+no-access+ws-no-access | 404 | 403 | PASS |
| m3 | 私有+no-access+ws-creator | 404 | 404 | PASS |
| m4 | 私有+no-access+ws-no-access | 404 | 404 | PASS |
| m5 | 非私有+no-access→createSync | 404 | — | PASS（同名镜像表 0 落地） |
| q1 | 非私有+零行+ws-creator | 200 | — | PASS |
| q2 | 非私有+editor+ws-no-access | 200（TRUE 探针） | 200 | PASS |
| q3 | 非私有+零关系+ws-no-access | 404（TRUE 探针） | — | PASS |
| q4 | 非私有+inherit+ws-creator | 200 | — | PASS |
| q5 | 私有+零行+ws-creator | 404（TRUE 探针） | — | PASS |
| q6 | 私有+inherit+ws-no-access | 404 | — | PASS |
| rel2 | 真零关系（src/dest 均无行，ws-no-acc） | 403/403（schema+list） | — | PASS（dest ACL 先拦，B.1 双码均过） |

## E. ACL 十端点 — PASS

- creator：list/get/source-schema/update/resync = 200；freeze/resume：syncing 态 400（运行中互斥，idle 态重测 200，T5）→ 合法码全覆盖；resolve-link 正路径（`/resolve-link`）= 501（沿袭 P2）；注：stage2 脚本曾误用 `/:id/resolve-link` 得 404 双端一致，属测试者路径误用，已用正路径重验
- editor：十端点（正路径）全 403（含 resolve-link 403）
- 匿名：list 401
- viewer：沿袭（R10 已验，零改动不复测；editor 403 蕴含 viewer 403 于 creator+ exclude 模型，Fork spec 第 115 行断言覆盖）

## F. 引擎 e2e + 守卫链 + 系统列 — PASS（修正版 e2e1b 全绿）

- full-create → active + `last_synced_at`；镜像 3 行 = 源 3 行，`RemoteId='1'/'2'/'3'`，`RemoteDeleted=false`
- delete 策略 resync：源改 row2→`row2-upd` + 删 row3 + 增 row4 → 镜像 3 行 `row1,row2-upd,row4`（upsert 双分支 + 删行）
- mark_deleted 策略：源删 row1 → 镜像 3 行保留，`{Title:row1,RemoteDeleted:true}`
- freeze → paused；paused resync → 400；resume → active
- realtime create → 400（付费锁）；update title/on_delete_action → 200；`selected_fields`（snake）→ 400（P2 灰区，沿袭）
- 守卫：insert 镜像表 → 400；DELETE 镜像表 → 400；editor 删镜像行 422 沿袭（本轮 creator 侧 400 已验，exclude 模型下 editor 只会更拒）
- 系统列：DB `nc_grid_view_columns_v2` 实测 `RemoteId/RemoteDeleted: show=false + system=true + readonly=true` 双保险；meta `columns[].show=null` 为沿袭表述差（R10 lane5 注记，不升级）

## G. 方法学注记（非发现）

- **D1 平台 ws-role 回显 stale**：`PATCH /api/v1/workspaces/:id/users/:uid` 返回的是**更新前行**（`roles` 字段为旧值），以紧随的 `GET /users` 为准。stage2 脚本曾按回显判断致 R5.2 假 404；TRUE 探针（回显 `workspace-level-no-access` + fresh signin）→ 200，消核
- **D2 脚本artifact×2（均已修正重跑，不报）**：①原 e2e1 用 `POST /records {"Id":2}` 做更新 → 插出重复行（5 行），改 body 式 PATCH；用 `POST /records/delete` → `Cannot POST`，改 body 式 DELETE；②`selectedFields` camel → update 侧只认 `selected_fields` snake。两处均为 R10-B.4 已有方法学，脚本 enact 遗漏
- **D3 平台 DELETE base-user 偶发 500**：删 mx src 行时 `basedel` 报 500（`roles=null` 悬挂行？），F09 侧各格仍返回预期码；TRUE 探针绕行后全绿。平台行为，非 F09 问题
- **S4 ws2 腿失效声明**：本轮开局把 `ws2` 经 invite 提为 ws-creator（为建 base），故 stage2 的 `ws2 list/schema = 200` 不是零关系证据；零关系由 TRUE rel2（403/403）覆盖
- **C1 向导打开路径**：Overview 卡片内层 DIV 直接 click 不触发（疑 promo 层遮挡），经组件自身 testid `proj-view-btn__create-new-sync` click 打开。组件行为正常，非缺陷
- **token 互踢**：API 与浏览器共用账号会互踢；本轮 API 用 `api` 系、UI 用 `uiown/uied` 系；admin token 中途过期一次，改用 api 账号执行 invite（super-bypass 同效）

## H. 质量门

| 门 | 结果 |
|---|---|
| 后端 tsc --noEmit | exit 0（141s） |
| jest 全 Fork 桶 | **41/41 passed**（3 suites，含 table-syncs.Fork 15/15；44s） |
| Vite URL 双 200 + overlay 全程 false | PASS（A 段） |

## I. 沿袭已知项（均未升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒、FAILED 泛型、resolve-link 501、realtime 400、editor 删镜像行 422、paused 菜单 Sync now 400、深链树骨架、source-schema 对无 allow_sync 视图仍 200（create 侧强制）、columns[].show=null 表述差。
