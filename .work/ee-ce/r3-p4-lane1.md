# F09 P4 R3 — lane 1（ZCode subagent）报告

**结论：PASS / 0 error + 2 minor**（R2 error 修复回归全过，P1–P4 站位无回归；2 minor 均为 R2 已知留存项，无新增）

审查基线 = 840c4218aa（R2 修复批；本轮审查期间 HEAD 曾推进至 8431d4ed8c，经核仅为 r3 任务书落盘、零源码变化，基线不受影响）。:8080 活体核验通过：health 200；pid 38535 启动 01:41:12 **晚于** dist mtime 01:34:28（`~/.nocodb-run/packages/nocodb/dist/main.js`，与工作树 dist 同 mtime 同尺寸）；dist 内 grep 修复特征串 "Link operations (link / unlink / reorder) are prohibited on synced table" 命中 ×2 ⇒ 运行包含 R2 修复。账号 `f09p4r3l1-api/-ed/-cr/-ui@ce-ee.local`；camoufox session `f09p4r3l1`；UI/API 账号分离。

## 1. R3 核心：R2 lane3 E1（v3 LTAR 通道绕守卫）修复回归 —— 全过

**静态**：`ltar-cols-updater.ts::updateForColumn`（:219-233）入口处新增 `baseModel.model?.synced → prohibitedSyncTableOperation`（422 同族，customMessage 与五入口一致），置于 `checkPermission` 之前、`addOrRemoveLinks` 直调之前；`assertLinkWriteAllowed` 改 public（BaseModelSqlv2.ts:6600）供复用。全仓调用图：`updateForColumn` 仅 v3 `nestedLink`（data-v3.service.ts:1600）一个消费方；`update`（bulk 档）仍经 trxBaseModel.removeLinks/addLinks 走既有守卫；引擎 junction 写（recomputeJunctionPairs/cleanupJunctionOrphans，processor :662/:495）raw knex 不经任何被守卫方法。

**活体**（主镜像 f09p4r3l1-sync，link 列 f09p4r3l1_L1，镜像行 s1[2 对]/s2[1 对]）：

| # | 探针 | 期望 | 实得 |
|---|---|---|---|
| G1 | owner v3 `POST /api/v3/data/:dest/:mirror/links/:col/2` 注入 [3] | 422 | **422** ERR_SYNC_TABLE_OPERATION_PROHIBITED |
| G2 | editor 同上（R2 症状 200/201） | 422 | **422**（不复现） |
| G3 | owner v3 DELETE unlink [1] | 422 | **422** |
| G4 | editor v3 DELETE unlink [1] | 422 | **422** |
| G5 | v3 GET links 读（editor） | 200 | 200 + 配对 [r1,r2] 正确（读放行） |
| G6 | 四次 422 后镜像配对复查 | 不变 | s1 L=2 / s2 L=1，无注入无丢失 |
| G7 | v2 records PATCH 带 link 字段（editor） | 拒 | 400 readonly-column 守卫（v2 update 路径先拦，未达 link） |
| G8 | v2 nestedDataLink POST（editor） | 422 | **422** |
| G9 | v1 alias relationDataRemove DELETE（owner） | 422 | **422** |
| G10 | v1 alias relationDataAdd POST（editor） | 422 | **422** |

**owner 合法路径不误伤**：owner 对**非 synced 源表** v3 POST/DELETE link → 200，配对真实写入/解除（本轮数据链全靠它搭建）。**引擎通道无 bypass 无误伤**：源加配对 s2→r3 → resync → 镜像 s2 L=2（r3 经 shadow 正确回填）⇒ 守卫激活下引擎 recompute 正常。

## 2. P1–P4 全矩阵站位

- **updateSync link 级联**：keep-link PATCH → 200、L1 列 id 不变（chcjl5wxphvdqc1）、三 mapping 保持、无拆毁；null PATCH → 全字段含 links；`[]` → 400（"selectedFields must be a non-empty array or null"）。
- **双 shadow 共享 + 自动 resync 回填**：源加第二 link L2（同 RT）→ PATCH null → mapping 变 main+**1 shadow（共享）**+2 junction；无手动 resync 而配对自动回填（镜像 L1: s1=2/s2=2；L2: s1=1=r3）。
- **删腿引用计数**：PATCH 去 L2 → junction2+镜像 L2 列删、**shadow 保留**（L1 仍引用）；PATCH 去 L1（末腿）→ junction+shadow 全清、mapping 只剩 main、标量数据无损。
- **paste 三件套**：paste + link 字段 → 400（文案含 browse-mode 说明，table-syncs.service.ts:1027）；paste sourceSchema 只列 Title 不列 link；paste 纯标量 → 200 建链成功（验证后已删，deleteSync 级联顺带回归）。
- **mark_deleted 两档一致**：mark_deleted+link 的 sync3 → 删源行 s2（原配对 2 条）→ resync → 镜像行**保留**且 `RemoteDeleted:true`、`L1=0`、junction 4→2（仅 s1 侧）⇒「配对恒镜像源 junction；行级策略只管行」活体成立。
- **AUTO（realtime）双档**：sync4 realtime：源插 s4 → 镜像 ~1s 出现（incremental）；源加配对 s4→r1 → junction ~4s 出现（link tap → full-resync，符合 ~5s 简化档）。
- **窗口 delete 收敛**：sync4 freeze → 删源 s4 → resume → 首次轮询内 s4Rows=0、junction 3→2（catch-up 全量 pass 含 sweep 收敛）。
- **E1 六格（P1 继承）**：caller（dest=creator/src=显式 no-access，非私有）source-schema → **404 ERR_BASE_NOT_FOUND** vs 平台 GET base **403**（修复格语义成立：存在性遮蔽）；createSync 同 caller → **404 且 dest 零落表**；私有+零行（非成员）→ F09 403 / PLAT 403 镜像 fail-closed。注：R2 修复批未触 assertSourceReadAccess（仅 2 个源文件），该面与 R2 pass 态逐字节相同，无回归可能；ws no-access 两格本轮未重推导（R2 已 pass 站位）。
- **ACL**：editor 对 table-syncs 九端点（source-schema/get/create/update/delete/resync/freeze/resume/detach）**全 403** fail-closed；owner 各 200。
- **UI 活体**（camoufox，:3000）：①向导三层：base home → NocoDB Sync → Browse → 选 base/table → 字段步 **Title/L1/L2 可选**（link 字段在 browse 向导可选，与 paste 分支不列 link 对照）→ Sync method 双档（Automatically/Manually）+ on_delete 双档（Deleted/Retained）→ Create → 树出现镜像+shadow（junction 默认隐藏，includeM2M API 可见）、API 4 mapping active；②树菜单：sync 行 "..." 菜单含 Synced table/Sync now/Pause sync/Convert to regular table/Delete sync；点 Sync now → `last_synced_at` 实际刷新（菜单执行链通）；③删除流：Delete sync → 确认弹窗 → 确认后**树不刷新页面即时移除**镜像+shadow，API 仅剩 3 sync（R5-M2 修复保持）；④editor 卡 gate：editor 开 dest base → 行菜单仅剩 TABLE ID，同步管理项全部不渲染（与 API 403×9 一致，fail-closed）；⑤zh-Hans：切简体中文后删除确认弹窗全中文（「删除同步|f09p4r3l1-sync — …|取消|删除同步」）。

## 3. Minor（均为 R2 留存，非本轮新增，不阻塞）

- **M1（R2 lane3 M1 留存）i18n 死键**：`msg.warning.syncPasteLinkUnsupported` 在 en.json/zh-Hans.json 各 1 处落位、全 nc-gui **零组件引用**；活体 400 文案仍为后端硬编码英文（table-syncs.service.ts:1027），zh-Hans 用户在 paste+link 拒收路径看到英文。接线缺口，功能不受影响。
- **M2（R2 lane3 M2 留存）spec 覆盖缺口**：table-syncs.Fork.spec.ts LTAR guard 仍为 4 例（addLinks/addChild/audit-only/普通表），removeChild/removeLinks/reorderLink 无断言；**v3 `updateForColumn` 通道零用例**（840c4218aa 未补测试，用例总数 60 与 R1 批一致）。本轮已用 10 支活体探针覆盖该缺口，但回归防线仍缺 spec 层。

## 4. 未核验 / 环境注记

1. R2 lane3 M3（源 link 列删除后 junction/shadow 惰性残留）本轮未复测（R2 已确认仍存，非 R3 重点清单项）。
2. E1 六格中 ws no-access 两格未活体重推导（代码路径与已测格同源：baseNoAccess 短路）。
3. camoufox daemon 本轮 3 次中途退出（审查工具层，非产品问题）——各次重启后流程续完，未影响断言；树菜单交互对合成事件不敏感，最终以聚焦元素+事件序列完成。
4. 测试账号 4 枚（f09p4r3l1-api/ed/cr/ui）无自助删除端点，留存于 org 用户表（前缀隔离，与历轮做法一致）；全部测试 base（f09p4r3l1-src/dest）、4 条 sync 及三层表已删净，临时 token/响应文件已清。

## 5. 纪律

只读审查：`git status packages/` 零本 lane 改动；未构建/未重启/未跑 dev-backend*.sh/未 pkill/未自愈（:8080 全程 pid 38535）；无 psql；未读他路 R3 报告（对照材料仅任务书指定链 r2-p4-lane-prompt / r1-p4-lane-prompt / r2-p4-lane3 / f09-p4-impl-report 及其引用的 impl 自测脚本）；测试数据全 `f09p4r3l1-` 前缀且已清；质量门：`npx tsc --noEmit` exit 0、`npx jest --testPathPattern 'Fork.spec.ts$'` **60/60**（3 suites）、Vite URL 门无对象（840c4218aa 零前端改动，impl §9 先例）。
