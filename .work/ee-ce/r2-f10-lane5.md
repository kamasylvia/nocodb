# r2-f10-lane5 — F10 R2 收敛确认（第 5 路：int 交叉抽验 + rev 交叉终审）

> 本文件覆写 R1 轮同名报告（R1 所列 error-1~5 已由 `294c79ef5d` 修复，本轮逐项复验）。

改动面：`6eb3b80c1d`（F07+F10 主实现）+ `294c79ef5d`（F10 R1 修复）。工作树干净（status/diff/untracked 全空）。
隔离声明：未读任何 r*.md 归档；只读 TASK.md、仓根 AGENTS.md、源码、运行系统。

## int — PASS

实测环境：dev server :8080（nocodb-dev），自建账号 r2lane5@ce-ee.local（org-level-creator + workspace-level-creator），HTTP 头 `xc-auth`（注：`Authorization: Bearer` 保留给 API token，JWT 必须走 xc-auth——测试姿势坑，非代码缺陷）。

1. dashboard CRUD 一轮（base-scoped `/api/v2/meta/bases/:baseId/dashboards`）：
   - create 200 → list 200(1 行) → get 200 → patch 200(title 改 + description=null 清空) → delete 200 → get 复读 404。全过。
   - 校验面全过：同 base 重复 title 400；全空格 title 400；title 256 字符 400；description=12345(非字符串) patch 400。
   - 特殊字符 round-trip：title 含 `<script>alert(1)</script>`、description 含 `création 测试 "quoted"` 原样存取（JSON 编码输出，无转义损坏、无注入面）。
2. 跨 base 隔离：baseB 路径 get/patch/delete baseA 的 dashboardId 全部 404（metaGet2 contextCondition 落 `where base_id` 过滤）；baseB list 空。全过。
3. 并发同 title：6 线程并发 create 同 title → 恰好 1 成功 + 5 个 400，**无 500**（service pre-check + DB unique index 双保险实测均未漏；R1 error-2 修复有效）。
4. pg8000 直查 nocodb-dev 核对：
   - `nc_dashboards_base_title_unique` UNIQUE INDEX ON (base_id, title) 存在（migration `nc_20260913_dashboard_title_unique.ts` 已生效）。
   - 删除的 dashboard 行物理删除（count=0）；幸存行 order 递增正确。
   - base 经 API delete 后其 dashboard 行全部被清（0 行）——`Base.ts` softDelete 挂钩实测生效。
5. ACL 负面：editor 角色 dashboardList 403 / dashboardCreate 403；不存在的 dashboardId 先 404 后 ACL（不泄露资源存在性，与 upstream 顺序语义一致）。
6. R1 error 复验：list 缓存一致（insert 先 materialize 再 appendToList，list 行数 = DB 行数）；重名拦截生效；FE store 无 activeDashboard 悬空引用（已删）、openDashboard 拼全路径 `/{wsId}/{baseId}/dashboard/{dashboardId}`；dashboard-only 路由已整体移除（500 根因消除）。

## rev — PASS

1. 安全：title/description 原样存储 + JSON 输出，前端 Vue 插值自动转义，无 XSS 面；knex 参数化无 SQL 注入；错误消息回显 title 走 JSON 响应无注入通道。`ncUtils.ts` isEeUI=false 未动；`Api.ts` 未动；nuxt.config `allowedHosts=true` hook 仅 vite dev server 配置（生产 build 不消费），无 prod 暴露。凭证面：diff 无敏感串，dev-backend.sh 运行时拉 Infisical。
2. 一致性：
   - `// [CE-EE]` 标记全覆盖（model/service/controller/extract-ids/acl×2/store/menu/useEeConfig/migration/Base.ts 挂钩）。
   - acl 双侧一致：后端 `permissionScopes` base scope 注册 4 op（dashboardList/Create/Update/Delete），base-scope CREATOR/OWNER exclude 模式天然放行 creator+、editor/viewer include 无 key → 403（与 F05/F07 同机制，实测印证）；前端 `lib/acl.ts` creator include 显式 4 op，editor 及以下无。双侧口径一致。
   - `Base.ts` 双挂钩在位：softDelete（L460）+ delete（L713）均调 `Dashboard.deleteByBaseId`，noco.module controller/service 注册齐全。
   - extract-ids：dashboardId 分支按 upstream else-if 链位（widgetId 之后），resolve 后填 `req.ncBaseId`/`context.base_id`；R1 已删无 baseId 段的 dashboard-only 路由（metaGet2 base_id assertion 500 根因消除）。
   - R1 修复点复核：Dashboard.insert 先 materialize 再 appendToList；update description 类型校验；migration 先 dedup 再建 unique index（幂等安全）。
3. 测试基建（实跑）：后端 `tsc --noEmit` exit 0；jest 2 suites / **26 tests 全过**（Fork 桶全量；任务书「12/12」为 R1 时点口径）；vitest 18 文件 16 过、**130 tests passed / 5 skipped**，2 个 fail 均为仓根 AGENTS §3.2 已记录的上游噪音（pwa-self-destroying 必败；formula-url-xss 并发抖动，单跑 5/5 过）。
4. lang：en/zh-Hans 的 `dashboardEmpty` / `navigateToBaseToCreateDashboard` / `youDontHaveAccessToCreateNewDashboard` / `general.dashboard` / `tooltip.switchToDataTab` 键双侧齐全。
5. commit 前清单：工作树干净，无未提交改动；commit message 含 what+why。

### 观察项（minor，非 error，不阻断计数；pass 收尾时处理）

- AGENTS.md 文档滞后（收尾同步义务，非代码 error）：L21 F10 状态仍「待做」；L30 已解 gate 清单缺 `blockAddNewDashboard`（代码已 =false，useEeConfig.ts:77）；L32 仍将 `src/models/Dashboard.ts` 列为 stub。建议 pass 收尾 commit 时同步，并在 §2 增补 F10 设计段（dashboard = titled container、widget 渲染 deferred、(base_id,title) unique 约束、base delete 级联清理）。
- `dashboards.service.ts` update：title 长度检查用 trim 前 `body.title.length`（create 用 trim 后），两侧不对称——只影响边界 255+空格的极端输入（update 更严），无漏洞。
- update 路径 check-then-update 竞态撞 unique index 理论上 500（create 实测竞态未触发；DB 兜底防重复成立），错误码欠优雅，属 R1 已知权衡。
- `deleteByBaseId` 的 list-cache deepDel key 与行级 key 清理依赖 base 删除级联；实测行为正确，记录备查。

## 裁决

- int：PASS
- rev：PASS
- 总裁决：**PASS**（0 error；4 条 minor 观察项，其中 AGENTS.md F10 状态同步为 pass 收尾待办）
