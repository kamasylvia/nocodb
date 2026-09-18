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
- [ ] F06 Docs Permissions — **fork 限制裁剪（2026-09-17 裁定）**：Docs 本体在 CE 零存在（Document.ts 纯 stub、v3 service 孤儿、前端零组件），权限面板无管理对象；DB schema + SDK 类型 + F02/F03 权限框架完整保留，待上游落地或用户指令重启（f06-research.md 三选项）
- [x] F04 Manage Syncs — **pass（2026-09-17，R3/R4/R5 连续清洁连击 3/3；实现 2fd09efccf + 修复链终 b6c95cb3ac/51b9637b84 hardening）**：legacy SyncSource 管理面板（列表/编辑/删除/重同步 watchdog）+ 双入口解 gate + i18n；App Sync 引擎裁掉待 F09 评估
- [ ] F09 Sync data — **P1 范围已裁定（Table Sync manual 最小闭环，交付即 pass）；R11 五路在飞（pass 冲刺轮：R9/R10 连续 0 error 连击 2/3，再清洁即 pass）**：P2 生命周期/P3 realtime/P4 LTAR 记分阶段 backlog；Custom Sync 裁记 fork 限制（f09-research.md）

## 待人工验证

- [ ] F01 会审 pass 后：用户在 UI 实测「Unique values only」交互体验
- [ ] dev server 常驻方式（后台 rspack）是否符合用户使用习惯

## 维护说明

- 环境与红线（数据库/凭证/构建命令）见仓根 `AGENTS.md`
- 每功能完成：勾选 + 归档报告 `.work/ee-ce/r<N>-f<NN>-<agent>.md` + 更新 `.work/ee-ce/GOAL-STATE.md`
- 功能顺序调整需同步 `TASK.md` 与本文件
