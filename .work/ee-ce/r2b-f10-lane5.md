# r2b-f10-lane5 — F10 R2 收敛确认（第 5 路：int 交叉抽验 + rev 终审）

实测环境：dev server 已重启至 R1 代码（commit 294c79ef5d），nocodb-dev，pg8000 直查核 DB。
隔离声明：未读任何 r*.md；只读 TASK.md / 仓根 AGENTS.md / 源码 / dev-backend.sh。

## int — dashboard CRUD 交叉抽验（1 轮，17 步）

PASS（全部实测通过，无 error）：

- LIST 200；CREATE 200；PATCH rename 200；PATCH description=null 200（R1 校验放行 null）；DELETE 200；删后 GET 404
- 边界：dup title 400 / title 非字符串 400 / 空+纯空白 title 400 / 256 字符 400 / description 非字符串 400（R1 新校验确认已生效）
- 越权：跨 base dashboardId 404；不存在 id 404
- XSS title（`<script>…`）创建+回显 JSON 原样，无 500
- 并发同 title ×5：1×200 + 4×400，DB 恰 1 行（pre-check + unique 约束收敛，无 500 无 dup）
- 401：无凭据 / 坏 token → 401
- 403：base 外用户 list/create → 403
- DB 终核（pg8000）：race 残留恰 1 行；dup(base_id,title)=0；约束 `nc_dashboards_base_title_unique` 存在；测试数据已清理

环境级发现（非代码 error，已现场修复，需 orchestrator 知悉）：

1. 原 dev server（04:41 起）跑的是 R1 之前的代码 → 已重启至 R1 代码后实测。
2. **R1 迁移 `nc_20260913_dashboard_title_unique` 在 nocodb-dev 从未执行**：`MetaService.init` 跑 v2 链的前提是 `xc_knex_migrations` 表存在且有记录，该库只有 `xc_knex_migrationsv0` → v2 链整体被跳过（含全部上游 v2 迁移，历史库状态问题，非 F10 代码缺陷）。已按迁移文件同语义手动补齐（dedupe 保留最早 + 建唯一约束）。**fresh 部署无此问题（迁移自动跑）；存量 dev 库需手动补，建议记入 AGENTS 运维段**。
3. dev-backend.sh stop 的 pkill 模式未能杀掉 dist/main.js 进程（两次重启均残留旧进程抢 8080），需手动 `pkill -f "dist/main.js"`。

## rev — 交叉面终审

issues（文档欠账，属实可验，非代码 bug）：

1. `AGENTS.md:21`：§1 状态表 F10 仍写「待做」——commit 6eb3b80c1d 已实现 F10 且同 commit 更新了 F07/F05/F01 行，独漏 F10 行，违反文档同批同步约定。
2. `AGENTS.md:30`：§2「本 fork 已解 gate」清单缺 `blockAddNewDashboard`（F10）= false。
3. `AGENTS.md:32`：§2 stub 后端 model 清单仍把 `src/models/Dashboard.ts` 列为 stub——已被真实 CRUD model 替换。
4. `AGENTS.md` §2.1 无 F10 设计段——建议补 fork 决策：dashboard = titled container（widget 渲染延后）；title 每 base 唯一 = 服务层 pre-check + DB 唯一约束双层；`/api/v2/meta/dashboards/:id` 无 base 路由已收窄删除；页面路由 `/{wsId}/{baseId}/dashboard/{dashboardId}`。并建议补上述环境级发现 2/3 两条运维坑（放 §3.2 或 F10 设计段）。

PASS 项（无 error）：

- 安全：title/description 类型强校验；`extractProps` 白名单防 mass-assignment（meta/order/created_by/owned_by 不可经 body 注入，created_by 取 req.user）；knex 参数化无注入面；无凭证/secret 通道；错误消息内插 title 为 JSON 反射点，低危。
- 一致性：`// [CE-EE]` 标记覆盖全部修改处（controller/service/model/store/menu/page/acl 前后端/extract-ids/migration/dataHelpers）；`ncUtils.ts isEeUI` 与 `nocodb-sdk` 未动；acl 双侧对称（前端 `lib/acl.ts` CREATOR 块 4 ops，后端 `utils/acl.ts` base scope 4 ops，creator+ only，editor/viewer 无）；`Base.ts` 双挂钩均在（softDelete L457 区 + delete L710 区）；`noco.module.ts` 注册齐全。
- 前端 gate：菜单项 `!blockAddNewDashboard` 独立 gate 且注释说明不叠 `isEEFeatureBlocked` 的原因；其它 upsell 项仍走 `showEEFeatures`（CE 隐藏语义不变）。
- 迁移：`XcMigrationSourcev2` import + 数组注册齐全；up 含 dedupe 前置；down 可逆。注：up 的 dedupe DELETE 不过滤 `deleted` 软删行（软删重复 title 会被物理清除）——dev 残留数据场景可接受，记观察不计 error。
- 测试基建（实跑）：`tsc --noEmit` = 0 错误；jest 2 suites 26/26 passed（基线 12，超出）；vitest 17/18 文件通过、130 passed + 5 skipped，唯一失败 = `test/pwa-self-destroying.test.ts`（AGENTS §3.2 已载上游噪音；上轮第 2 个失败 formula-url-xss 为已知并发抖动，本轮重跑自愈）。F10 无专项 jest/vitest 用例（基线不要求，集成实测已覆盖，记观察）。

观察项（非 error，不要求修）：

- `store/dashboard.ts` 删除了 `activeDashboard` / `activeDashboardId` / `isEditingDashboard` 导出，上游组件 `components/smartsheet/Topbar.vue:10` 与 `components/dlg/share-and-collaborate/View.vue:19` 仍 storeToRefs 解构 → 运行时 undefined（与上游 stub null 行为等效，无崩溃；fork dashboard 走独立路由，Topbar 不在其渲染树）。
- store 的 `loadDashboards` / `loadDashboard` / `openDashboard` / `updateDashboard` / `deleteDashboard` 当前无调用者（dashboard 页面直用 `$api`）——死代码，后续 widget 层落地时可清理或接线。
- `Dashboard.ts` `softDelete` 与 `delete` 实现完全相同（无害重复）。

commit 前清单：工作树 clean（`git status` 空）；F10 改动 = commit 6eb3b80c1d（F10 部分）+ 294c79ef5d，与声称改动面一致；无未跟踪遗漏。文档欠账（上述 issues 1-4）需随下一 commit 同批补齐。
