你是 NocoDB CE-EE fork 的 F04 Manage Syncs 第 1 轮复审（R1）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/f04-research.md`（调研报告 = 范围裁定依据），再读本任务书。

## 铁律
- **只读审查**：严禁修改/新建任何仓库源码文件。只允许写报告文件和 /tmp 测试脚本。
- **隔离**：禁读 `.work/ee-ce/r*.md` 历史报告与他路报告。可读 TASK.md、AGENTS.md、GOAL-STATE.md、f04-research.md、源码。
- **数据库红线**：只用 `nocodb-dev`（后端 :8080 已连）。严禁 `nocodb` 生产库。
- 输出压缩中文。

## 环境
- HEAD = main 分支最新（F04 实现 commit 2fd09efccf，前端 6 文件，后端零改动）。先 `git log --oneline -5` 确认。
- 后端 :8080 / 前端 :3000（浏览器直连 :8080；curl :3000/api/* 返回 HTML 是设计行为）。
- 测试账号自建 f04r1lN-* 前缀（owner 建新账号需提权 workspace 角色才能建 base——用 super API 或沿用 f03r3-owner@t.local / F03r3-Passw0rd! 作 owner）。
- 报告落盘 `.work/ee-ce/r1-f04-laneN.md`。测试资产清理（仅自己前缀）。

## F04 范围裁定（复审基准）
- 做：Manage Syncs 面板 = legacy SyncSource（Airtable sync）管理——列表/编辑（title+details JSON）/删除/手动重同步（atImportTrigger + $poller）；双入口解 gate（base settings syncs tab + 侧栏菜单，flag=blockSync=false + role=sourceCreate creator+）；空态引导；i18n 14 键。
- 裁掉（存在即报 error）：App Sync（SyncConfig）UI 暴露（isSyncFeatureEnabled 必须 false；integrations/AddConnection 等三消费组件不得出现 App Sync 创建入口）；Table Sync；SyncLogs UI；15min 调度；enabled 启停语义。
- 后端零改动：diff 必须不含 packages/nocodb/src 任何变更。

## 复审清单
1. **diff 审查**（commit 2fd09efccf 单提交）：6 文件改动与调研方案一致性；blockSync 解锁注释；isEeUI 移除仅限 syncs 查询 watch；store/sync.ts 未动；i18n 键 en+zh-Hans 双份且路径与组件 t() 一致。
2. **ACL/角色矩阵**（API 实测）：owner/creator 对 `/api/v2/meta/bases/:id/syncs` CRUD 全 200；editor/viewer list+create+patch+delete 全 403；匿名全 401/404。
3. **CRUD e2e**：创建（type Airtable + details）→ 列表含该行 → PATCH title/details → DELETE → 重列归零。
4. **UI 段**（camoufox，owner 会话）：base settings 侧栏出现 Manage Syncs 菜单（badge 存在）→ 点击 → 面板渲染（空态文案）→ （用 API 预建 1 条 sync 后刷新）列表卡片渲染、Edit 显示 title/JSON、保存落库、Resync 按钮触发（无真实 Airtable 凭证时报错路径=预期，fork 限制）、Delete 确认后消失。console error 与 Nuxt overlay 双零。
5. **editor UI 隔离**（editor 会话）：settings 侧栏**无** Manage Syncs 菜单项；直接 URL `#/nc/:baseId/settings/syncs` 不得渲染面板（应无 .nc-base-syncs）。
6. **App Sync 隔离**：workspace Integrations 页、base Integrations tab 不得出现 App Sync 创建入口（isSyncFeatureEnabled=false 未变）。
7. **回归 smoke**：F02/F03/F05/F07/F08/F10 各一探针； AirtableImport 向导（若可走通创建段）不回归。
8. **质量门**：`cd packages/nocodb && npx tsc --noEmit` exit 0；jest 26/26（前端无测试基线，不强制 vitest）。

## 已知 E3（勿计 error）
- v1 bulkUpsert 500、v1 title 寻表 404、sharedView meta、duplicate >1000 行、后端 dev 库 700+ 测试账号噪声。
- 重同步全链路需真实 Airtable 凭证（fork 限制，研究 §7）。

## 报告格式
首行 `PASS（0 error）` 或 `issues（N 项）`；issues = `文件:位置:问题:建议`；E3 单列附证据。
最终回复：结论 + issues 摘要 + 报告路径。
