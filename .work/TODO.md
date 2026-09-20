# TODO.md — nocodb CE-EE fork 工作区

> 状态唯一判据。完成即勾选/移入维护说明。流程正本见 `.work/ee-ce/TASK.md`，当前状态见 `.work/ee-ce/GOAL-STATE.md`。

## 待办（按推进顺序）

- [x] F05 Variables (base variables) — **pass（R5/R6/R7 连续 3 轮 0 error，commit 6ab23da061）**：后端 CRUD API + secret 加密守卫 + UI 管理页 + ACL + i18n + 单测 12 + 缓存双重解密 CE 原生洞修复
- [x] F07 Manage Snapshots — **pass（commit bc409929da）**：R5/R6/R7 三连 0 error；快照=异步完整副本 + restore=复制为新 base + 全链安全实测
- [x] F01 Unique values only — **pass（commit 744d31618b）**：R6/R7/R8 三连 0 error（新编制每路 int+rev），18 error 全修，UI 开关往返浏览器实证
- [x] F10 Create Dashboard — **pass（commit ab31f60fe3 + R1 修复 294c79ef5d）**：dashboard CRUD + 页面骨架 + 菜单入口 + extract-ids dashboardId + 标题唯一迁移（R2 期并入 v0 source 修正）
- [x] F08 Base Type - Private — **pass（连击 R2/R3/R4 = 3/3，2026-09-14，实现 6aea3db097 + 四轮修复 2a86eb7d6c/b1d3ec3c5b/c8e0c83e0f/e737f8f3ec）**：is_private 列 + 404 遮蔽 + boolean 严格化 + legacy token 拒认 + shared-base 三层拦截 + duplicate 四路继承 + UI Base Type 面板 + palette 过滤；4 轮会审累计修 13 项
- [x] F02 Edit field permissions — **pass（2026-09-14，R7/R8 连续清洁连击 3/3；实现 4b26d7a23f + 七轮修复终 ca6c81f5a6）**：字段级编辑权限全链路（nc_permissions 表/8 数据挂点/CRUD API/UI 弹窗+Details tab/交叉重名防劫持）
- [x] F03 Data permissions — **pass（2026-09-16，R4/R5/R6 连续清洁连击 3/3；实现 7b10716231 + 修复链终 51b9637b84）**：TABLE_RECORD_ADD/DELETE/VISIBILITY 全链路 + duplicate/restore 带 grants + 加固批（context.permissions memo 消费，bulk 放大 5x 消除）
- [ ] F06 Docs Permissions — **fork 限制裁剪，用户确认维持 C（2026-09-18）**：Docs 本体 CE 零存在；可逆（f06-research.md A/B 选项存档）
- [x] F09 Sync data P2 — **PASS（2026-09-19，R2/R3/R4 连击 3/3；实现 a4959c27cd + 修复链终 253c3b6ee5）**：paste 模式（uuid+bcrypt 凭据持久化）、selected_fields 增删传播、源列类型漂移传播、detach 转正、灰区修复（resync 复检/原子性/空数组）+ editor 卡 gate/hash URL/凭据剥离
- [x] F09 Sync data P3 — **PASS（2026-09-20，R3/R4/R5 连击 3/3；实现 f6a9314b5e + 修复链终 45032e45b0）**：realtime 五处 tap → CAS 分发 → incremental affectedIds/水位双路 + AUTO 解锁 + 向导双档 + resync 响应收敛 + Convert 瞬空白修复
- [x] F09 Sync data P4 — **实现批完成（2026-09-20，质量门 tsc 0 + jest 47/47 + 活体 12 步 ALL PASS + realtime/detach/标量回归 probe 全过；待会审闭环）**：LTAR 三层（Main link 列 + LinkedShadow + Junction，RemoteId 配对）+ removeSyncedLinkFieldDropsJunctionShadow 级联 + deleteSync/detachSync 全表级联 + realtime link 变更投全量 resync（已批简化档）；详见 .work/ee-ce/f09-p4-impl-report.md
- [x] F04 Manage Syncs — **pass（2026-09-17，R3/R4/R5 连续清洁连击 3/3；实现 2fd09efccf + 修复链终 b6c95cb3ac/51b9637b84 hardening）**：legacy SyncSource 管理面板（列表/编辑/删除/重同步 watchdog）+ 双入口解 gate + i18n；App Sync 引擎裁掉待 F09 评估
- [x] F09 Sync data — **P1 PASS（2026-09-18，R9/R10/R11 连续清洁连击 3/3；实现 71896a841f + 修复链终 5e3d736b2a）**：Table Sync manual 闭环（browse 镜像/RemoteId 键控 upsert/双删除策略/freeze-resume/delete + 向导/树菜单/Overview/Share 四入口 + 平台谓词六格矩阵）；P2 生命周期/P3 realtime/P4 LTAR 记分阶段 backlog；Custom Sync 裁记 fork 限制（f09-research.md）

## 待人工验证

- [ ] F01 会审 pass 后：用户在 UI 实测「Unique values only」交互体验
- [ ] dev server 常驻方式（后台 rspack）是否符合用户使用习惯

## 维护说明

- 环境与红线（数据库/凭证/构建命令）见仓根 `AGENTS.md`
- 每功能完成：勾选 + 归档报告 `.work/ee-ce/r<N>-f<NN>-<agent>.md` + 更新 `.work/ee-ce/GOAL-STATE.md`
- 功能顺序调整需同步 `TASK.md` 与本文件
