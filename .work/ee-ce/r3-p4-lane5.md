# F09 P4 R3 修复回归 — lane 5（UI 验证重点路）报告

**结论：PASS（0 error + 3 minor；3 minor 均为 R2 已知遗留，R2 修复批范围只含 E1，非新增、不阻塞）**

- 审查基线 = 840c4218aa（R2 修复批）；后端 :8080 = `~/.nocodb-run/dist`（mtime 09-22 01:34）+ 进程 38535（01:41:12 启动）——**「进程启动晚于 dist mtime」双条件成立**，dist 内 grep 到守卫文案 `manage the links in the source table` ×2。全程未构建/未重启/未 pkill/未跑 dev-backend*.sh。
- 账号前缀 `f09p4r3l5-*`（api=owner / ed=editor / ui=owner-UI / edui=editor-UI，UI 与 API 分离）；camoufox session `f09p4r3l5`（已关）；脚本 `.work/ee-ce/f09p4r3l5-{setup,run1,run2}.sh`。
- 活体计数：run1 **19/19 PASS**（v3 守卫 + 引擎通道）+ run2 **17/2**（2 FAIL 经查均系脚本错误，修正后复验 PASS，见 §2.3）+ UI 活体 6 项全过（6 截图落盘）。

## 1. R2 E1（v3 LTAR 通道守卫）修复回归 — 闭口

**静态**：守卫落位 `ltar-cols-updater.ts:223`（`updateForColumn` 入口、先于 checkPermission 与 `addOrRemoveLinks`，`// [CE-EE] F09 P4-R2(lane3 E1)` 标记）；批量档 `update()` 不重复加守卫但经 `trxBaseModel.removeLinks/addLinks` 汇入方法级守卫；`BaseModelSqlv2.ts` `assertLinkWriteAllowed` 定义 :6600 + 五挂点 :6657/:7053/:8925/:8945/:8968 无回退。

**活体（:8080 修后 dist）**：

| # | 断言 | 实测 |
|---|---|---|
| 1 | editor `POST /api/v3/data/:dstBase/:mirrorTable/links/:mirrorNsCol/:rowId` 注入源中不存在的配对 | **422** + `ERR_SYNC_TABLE_OPERATION_PROHIBITED` + updateForColumn 专属文案（R2 症状 200/201 不复现）|
| 2 | owner 同端点注入 | **422**（守卫与角色无关，同 v2 口径）|
| 3 | editor/owner `DELETE` 同端点解除**真实配对** | 均 **422** |
| 4 | 第二条 junction（Ns2）通道注入 | **422**（双 junction 全覆盖）|
| 5 | 守卫后 junction 配对 | Ns=3 / Ns2=1 **一字未动** |
| 6 | owner 合法路径不误伤 | 源表 v2 加腿 201 / 解除 200；源表 **v3** 加腿 200 / 解除 200（非 synced 表不受影响）|
| 7 | 引擎 raw-knex 通道无 bypass | 源加边 p3→n1 → resync → Ns junction **3→4** 自动重算（status=active）；撤边 → resync → **回 3**；mirror link 读路径正常（p1→n1,n2）|

注：v3 批量档（`PATCH /api/v3/data/.../records` 携 link 字段）未活体构造（DataUpdateRequest link payload 形态预算内未拼出）；该路径代码面经 `update()` → trxBaseModel.addLinks/removeLinks 汇入守卫，且有 P1 镜像 readonly 前置 400 兜底，风险不成立。

## 2. P1-P4 全矩阵站位（活体抽查）

### 2.1 三层结构 + updateSync 级联（族 1 不回归）

- createSync `[Title,Qty,Ns,Ns2]`（manual）→ main + linked_shadow + **双 junction** 四映射，active，Ns junction=3 配对、Ns2 junction=1、shadow=3 行。
- keep-link PATCH `[Title,Qty,Ns]`：Ns 列 id 不变（cwnn9d04p2wvuv0）、mappings=3、Ns junction 数据保留=3、Ns2 junction mapping 拆除 + junction 表 404。
- null PATCH：mappings 回 4（Ns2 重建）、Ns 列 id 仍不变、双 junction 恢复 + **自动 full-resync 回填** Ns junction=3（无手动 resync）。
- `[]` PATCH → 400 `selectedFields must be a non-empty array or null`。

### 2.2 paste 双腿（族 4 不回归）

- paste createSync 选 link → **400**，消息含 browse-mode 说明；paste 纯标量 → **200**（不误伤）；paste sync 测完即删（200）。

### 2.3 ACL / E1 六格抽查

- editor createSync → **403**；editor 镜像插行 → **400**；editor 镜像改名（meta）→ **403**；updateSync 未知字段 → **400**。
- run2 首轮 2 FAIL（junction 计数、RemoteDeleted）经查均为**脚本错误**：① 双 junction 分表计我按合计断言（实为 Ns=3 + Ns2=1）；② 源行删除误用不存在的单行 DELETE 路由（正确形态 `DELETE /tables/:id` bulk + body）。修正后重跑：**delete 档 + mark_deleted 档双双 PASS**（见 2.4）。

### 2.4 mark_deleted / delete 两档一致（族 6 不回归）

- **delete 档**（s1，on_delete_action=delete）：bulk 删源 p2 → resync → 镜像行 3→2（p2 行删除）+ Ns junction 3→2（p2-n2 配对清理）、status=active。
- **mark_deleted 档**（s2-md，onDeleteAction=mark_deleted）：bulk 删源 p3 → resync → 镜像行保留 + `RemoteDeleted=true` + **被 flag 行 junction 配对同步清理**（Ns2 junction 1→0）——两档统一「配对恒镜像源 junction」。

## 3. UI 活体（camoufox session f09p4r3l5，截图落盘 .work/ee-ce/）

1. **向导三层建同步**：空态「NocoDB Sync」入口 → Browse 选 SRC → T1 → 字段步列出 Title/Qty/**Ns/Ns2**（link 字段真实解析可勾选）→ 手动档建成 → 树出现 `f09p4r3l5-s3` + `f09p4r3l5-s3 T2` 双节点（API 复核四映射 active）。截图 `f09p4r3l5-wizard-tree.png`。
2. **镜像 link 列真实解析 + 写守卫**：s3 网格 Ns 单元格 chip「2 f09p4r3l5-s3 T2s」→ 双击展开解析出 **n1/S-n1、n2/S-n2**；展开弹窗**无加关联/删关联入口**（UI 写守卫与 API 422 同口径）。截图 `f09p4r3l5-mirror-linkresolve.png`。
3. **树菜单三态 + Syncing 守卫**：Active（同步表 + Sync now/Pause/Convert/Delete 全项，`f09p4r3l5-menu-active.png`）→ Pause 生效（API paused）→ Paused 态（Paused 标记 + Resume sync，`f09p4r3l5-menu-paused.png`）→ Resume 生效（active）→ API 触发 resync 瞬间开菜单 = **仅剩 Syncing 一项，Sync now/Pause/Convert/Delete 全部隐藏**（`/tmp/l5_menu_syncing.png`，守卫成立）。
4. **zh-Hans Convert 弹窗全中文**：语言切 zh-Hans（经应用自身持久化键 `nocodb-gui-v2.lang`，等价语言菜单写入路径）后树菜单全中文（表格编号/立即同步/暂停同步/转换为普通表/删除同步），Convert 确认弹窗 = 标题「转换为普通表」+ 正文 `f09p4r3l5-s3 — "f09p4r3l5-s3"` + 按钮「取消 / 转换为普通表」**零英文残留**。截图 `f09p4r3l5-zh-convert.png`。
5. **删除流三腿**：树菜单删除 s2-md → 确认弹窗（`f09p4r3l5-delete-confirm.png`）→ 确认后 **① sync 行 404；② main/shadow/双 junction 四表全 404（树双节点同步消失）；③ 导航回落 base home（URL `/w9qi3ljd/pkmpsks7p7jbln9`，无死链无白屏）**。
6. **editor Overview 卡 gate**：editor-UI（edui）打开 base = 无「新建」入口、镜像网格「新增记录」disabled、`?page=overview` 被重定向到受限 settings、全程无总览/表同步卡；owner 阳性对照 = base home「表同步」卡可见。静态闭环：`lib/acl.ts` editor include 无 `projectOverviewTab`/`sourceCreate`，`Overview.vue:138` `isUIAllowed('sourceCreate')` 卡 gate（P2-R3 修复不回归）。

## 4. 质量门

- `npx tsc --noEmit`：**exit 0**（/tmp/l5_tsc.log）。
- `npx jest --testPathPattern Fork`：**60/60，3 suites**（/tmp/l5_jest.log）。
- Vite URL 门：5 个 F09 SFC（CreateNewSync / Sync:index / Sync:Form / SyncStatusBadge / SyncMenuOptions）`/_nuxt/...` 全 **200**。
- 工作树：`packages/` 零改动（git status 仅 .work 未跟踪脚本/截图）。

## 5. Minor（3，均为 R2 lane3 已判定遗留，本轮 R2 修复批范围 = E1 only，维持不阻塞）

- **M1**：`msg.warning.syncPasteLinkUnsupported` 仍为死键（en.json:5314 / zh-Hans.json:3704 在册，nc-gui 零组件引用；paste+link 400 运行时文案 = 后端硬编码英文，zh-Hans 用户在拒绝路径见英文）。
- **M2**：spec 仍无 v3 `updateForColumn` 通道用例（table-syncs.Fork.spec.ts LTAR guard 仍 R1 版 4 例：addLinks/addChild/audit-only/普通表）；本轮以活体补位，结构性缺口维持记录。
- **M3**：源 link 列删除后 junction/shadow 惰性孤儿维持（table-syncs.service.ts drop 循环通用分支，只删镜像列 + mapping 行，不走 dropMirrorLinkColumn/dropShadowForRelated）。

## 6. 清理与纪律

- 测试数据全清：s1/s3 sync 删除 200，s2-md 已随删除流删（404）；SRC/DST base 删除 200；infra 名册复查 **f09p4r3l5 残余 bases = 0**；paste sync 已删。账号 4 枚保留（无数据，供复测）。
- 只读纪律：未改任何源码；未构建/未重启/未 pkill/未跑 dev-backend*.sh；无 psql/未提权；隔离（未读任何他路 R3 报告；R2 lane3 报告为任务书指定对照）；token 仅存 /tmp；测试脚本与截图落 `.work/ee-ce/`（白名单）。
- 备注：UI 语言切换用应用持久化键直写 + reload（等价语言菜单产物），非接口旁路；其余 UI 操作全部页面真实点击/键盘事件。

**结论头：PASS / 0 error + 3 minor**
