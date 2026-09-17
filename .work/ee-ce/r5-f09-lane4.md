# F09 R5 lane4 复审报告（commit f81e24a4f4 回归 + 全矩阵）

> lane 4（重派 attempt2；attempt1 残留已归档 r5-f09-lane4-attempt1.md，未读、零采信）/ 账号 f09r5l4b-* / camoufox session f09r5l4b / 2026-09-18
> 结论：**1 error（E1）+ 1 minor（M1）+ 2 observation（O1/O2）**。R5 修复批（assertSourceReadAccess 重写）四象限修复生效，但重写后谓词与平台谓词仍存在一个象限偏差（显式 no-access base 角色 × 非私有源 base），API+引擎全链实证为访问控制泄漏。

---

## E1（error）assertSourceReadAccess 第 4 象限：非私有 + 显式 base 角色 = no-access + ws 角色可读 → 放行（平台拒绝）

**位置**：`packages/nocodb/src/services/table-syncs.service.ts:107-127`（R5 重写 f81e24a4f4）

**根因**：代码实现 `hasExplicitBaseRole || hasWsRead → 放行`（非私有分支），但平台谓词（BaseUser.ts:563-631 列表 SQL + User.getWithRoles:629-700）中 path 2（workspace 继承）**要求 base 角色 ∈ {NULL, 'inherit'}**。显式 `no-access`（`ProjectRoles.NO_ACCESS = 'no-access'`）行两条 path 均不命中 → 平台全链拒绝该用户。commit message 自述谓词（"base role null/inherit ∧ workspace role ≠ no-access → read"）与代码实现不符。

**平台对照证据**：
- SQL path 1：`roles != 'no-access' AND roles != 'inherit'` → no-access 排除
- SQL path 2：`roles IS NULL OR roles = 'inherit'` 才回落 workspace 角色 → no-access 排除
- `User.getWithRoles`：显式 base 角色非 'inherit' 时直接 `extractRolesObj(roles)` → effectiveBaseRoles = {no-access} → 请求上下文 ACL 全拒

**实测（API 全链，bna = dest creator + ws-level-editor + srcPub 显式 base 角色 no-access）**：
| 探针 | 结果 |
|---|---|
| F09 sourceSchema（dest→srcPub） | **200**，返回完整 base/table/view/column 元数据 |
| F09 createSync（同源，allow_sync=on） | **200**，sync 创建 + job 投递 |
| 引擎执行 | **active + last_synced_at，3 行源数据完整镜像**（RemoteId 1/2/3, Title/Qty 全量） |
| 平台对照 GET /api/v2/meta/bases/srcPub（同账号） | **403** |
| 平台对照 GET srcPub/tables（同账号） | **403** |

即：被平台显式封锁的用户可经 F09 API 浏览源 base schema 并**真实复制其数据**。该象限是 R2→R5 修复链（hide-existence / 拒零关系用户）同一危害等级的残余缺口。

**修复方向**：非私有分支的 workspace 继承仅在 `baseRole === '' || baseRole === 'inherit'` 时参与（现 `!hasExplicitBaseRole && !hasWsRead → deny` 未约束 path 2 的 base 角色前置条件），private 分支保持不变。

---

## M1（minor）创建向导 NcSelect 传入无效 `filterable` prop — 源 base 选择器不可搜索

`CreateNewSync.vue:189`（table 选择器 :196 同）：`filterable` 不是 NcSelect 的 prop（`components/nc/Select.vue` props = showSearch/filterOption/...）→ 被忽略，下拉为纯滚动列表。dev 库 258 base 场景只能虚拟滚动查找（实测滚动到底可达）。真实环境 base 少时影响小，但与代码意图（可搜索）不符。修复：改 `show-search`。

## O1（observation）browse 模式实际同工作区限定

`loadSource` 的 sourceContext 保留 dest 工作区 workspace_id → `Base.get`（metaGet2 带 `fk_workspace_id` 条件）对跨工作区源 base 返回 null → 404。跨工作区 sync 不可达（含合法的双工作区成员场景），与 paste 模式（i18n："handy for syncing from another workspace"，P2）分工一致；NocoCache 按 workspace 命名空间隔离，无泄漏路径。非缺陷，P2 放开 paste 时注意。

## O2（observation）UI 细节两则（不阻塞）

- 树节点 tooltip 未捕获到 sync 状态行（实测 hover 显示 VIEW NAME/VIEW MODE；SyncStatusBadge 状态行未现身——可能仅非 active 态渲染或需精确命中 table 节点 hover，未定论不计缺陷）。
- NcSelect 虚拟列表的 aria 快照仅暴露前 2 项（自动化/无障碍面；截图证实实际渲染完整列表）。

---

## 复审清单 8 项结果

1. **diff 审查 ✓**：R5 修复批 = f81e24a4f4 单文件（table-syncs.service.ts）；F09 全链 7 commits（71896a841f → f81e24a4f4）。[CE-EE] F09 标记：service×10 / model×1 / controller×2 / processor×4 / jobs-map×3 / noco.module+jobs.module×2 全在位。禁改文件（store/sync.ts、syncUtils.ts、acl.ts、ncUtils.ts）自实现基线零改动（git diff 71896a841f^..HEAD 为空）；`isSyncFeatureEnabled` 恒 ref(false)。
2. **引擎 ✓**：RemoteId 键控 upsert 实测正确（源 Qty 2→22 传播至镜像）；源/目标双侧 500/页分页循环；`engineWriteParams`（allowSystemColumn+skipPermissionCheck+skipAttachmentOwnershipCheck+skip_hooks）仅 job 内部，HTTP 不可达（editor 写全 4xx）；失败路径落 status=error+last_error（本轮无失败例，代码路径核验）；成功落 active+last_synced_at（实测）。
3. **服务 ✓（除 E1）**：R5 四象限修复生效——private+inherit/null→404 ✓、非私有+ws-no-access+零关系→404 ✓（na 账号还原 ws-no-access 后实测 404，平台对照 403 一致）、非私有+显式角色+ws-no-access→放行 ✓（cr 经 ws 继承 200，平台对照 200 语义一致）；E1 为残余第 5 象限。allow_sync 强制（resolveSourceView 双路径 400）、镜像列过滤（Title/Qty 进、系统列/附件/软删列排）、保留名守卫、realtime 400（service:312）、system:true 后置补丁（实测 meta system=true）——后四者本轮代码核验 + 前轮已实测，未重复构造。
4. **ACL 矩阵 ✓（除 E1）**：own/creator 十端点 200（个别 400 为状态机互斥、404 为已删，均非 ACL）；editor/viewer 十端点全 403；匿名 401；resolve-link 501（已知）；creator 可 delete/update 任意 sync（creator+ 语义，符合设计）。
5. **引擎 e2e ✓**：full-create（UI 向导与 API 双路径）→ RemoteId 对照（与源 pk 对齐）→ resync upsert（Qty=22）→ on_delete_action=delete（消失行删）→ 切 mark_deleted（消失行 RemoteDeleted=true）→ 源行重现（新 pk）→ resync 后 RemoteDeleted=false + 新行插入 → freeze（resync 400）→ resume → deleteSync 200 → sync GET 404 + 镜像 meta 404 + 再删 404。
6. **守卫链 + 系统列 ✓**：editor 对 synced 表 insert 400 / update 400 / delete **422**（ERR_SYNC_TABLE_OPERATION_PROHIBITED，同守卫族）/ 删表 400（"Synced tables cannot be deleted"）；树节点 Delete table 项按 `!table.synced` 隐藏；RemoteId/RemoteDeleted meta `system:true + readonly:true`，grid-columns 恰 2 列 show=false，网格截图无系统列，New record 灰置。
7. **UI ✓**：向导三步 **Back/Next/Create 按钮在 body 渲染且可用**（R2 E1 回归点；三步推进 + 真实建同步成功 + 树出现 synced 图标表）；管理菜单 Sync now/Pause/Resume/Delete 全项，Pause→Resume 标签翻转实测；Share 弹窗 allow_sync 开关双向切换持久（无 paywall badge）；**editor 三入口全不可见**：① Overview 卡（projectOverviewTab 为 creator-only，lib/acl.ts:126，editor 无 Overview 标签页）② 树 sync 菜单（tableSyncList 403 → useTableSync sync=null → `v-if="sync"` 整块隐藏）③ Share 弹窗无 Allow sync 区块（截图 e11）；console error 0、Nuxt overlay 0（window error collector 全程采集 + 全截图无 overlay）。
8. **回归 + 质量门 ✓**：tsc --noEmit exit 0；jest Fork 桶 41/41；探针全绿——F08（私有 base：own 200 / creator 404）、F07（snapshots create/list 200）、F05（variables 200）、F10（dashboards 200）、F02/F03（permissions 200）、F04/Airtable（syncs list 200 + store/syncUtils 零改动即不回归）。

## 已知限制 / 非问题（沿袭，未重复计）

resync 全字段盲刷；附件列不镜像；保留名 400；selected_fields 变更拒收（P2）；realtime 400（付费锁）；resolve-link 501；FAILED 详情泛型；createSync 非原子孤儿表（R2 known）；selected_fields:[] 空数组（R2 known）；dev 库存量测试账号噪声；token_version UI/API 互踢（本轮探针自身受此影响两次，测试方法项非产品项）。

## 纪律留痕

只读审查（零源码修改）；数据全 f09r5l4b-* 前缀，bases/syncs 已全删（404 验证）；bootstrap 仅用共享账号 f01e2e 做角色提升与建我前缀资源（未触其存量数据）；未动 dev-backend*.sh / pkill / 后端重启，8080 全程健康（结束复验 OK）；camoufox session f09r5l4b 已关闭；截图 20 张在 /tmp/f09r5l4/shots/（w1-w9 owner 流程、e1-e11 editor 流程）。
