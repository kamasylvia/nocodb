# TASK.md — nocodb CE→EE 功能移植长程任务书

> ~~本项目由 ZCode 全面接管，不走全局 AGENTS §11 多路复审外部 CLI 阵容~~（**2026-09-14 修订**：F02 R7 起改用全局 §11 外部 CLI 阵容——omp/pi/kilo/reasonix + ZCode subagent 混编；**所有路必须含 UI 段测试**（camoufox-cli）；阵容正本 `~/.agents/config.toml`（Resilio 同步）；**R9 起实际启用外部阵容：omp/pi/kilo/reasonix 4 路 CLI + ZCode subagent 补位，所有路含 UI 段**；连通性 2026-09-14 4/4 通过）
> 全局约束：`~/.zcode/AGENTS.md`；项目约束：仓根 `AGENTS.md`。

## 目标

在 CE 源码上补齐 10 项 EE 功能（清单见仓根 `AGENTS.md` §1 表），每项功能经会审连续 3 轮 0 error 后 pass，全部 pass 则项目完成。

## 功能顺序

F01 Unique → F05 Variables → F07 Snapshots → F10 Dashboard → F08 Private Base → F02 Field Permissions → F03 Data Permissions → F06 Docs Permissions → F04 Manage Syncs → F09 Sync data。
（顺序原则：先易后难、先自包含后耦合；可在 GOAL-STATE 里按实际依赖调整，调整须同步 `.work/TODO.md`。）

## 单功能工作流（每功能一轮循环）

1. **调研**：读该功能全部 gating 点（参考仓根 AGENTS.md §2 与 `.work/ee-ce/` 内已归档地图）；明确 CE 已有件（schema/model/SDK 类型）与缺口（service/controller/UI）。
2. **实现**：
   - 前端：解 `useEeConfig.ts` 对应 gate、替换 `<NcSpanHidden />` stub 组件为真实 UI；
   - 后端：补缺的 service/controller/model 逻辑；权限面接 `checkPermission` hook；
   - 所有修改加 `// [CE-EE]` 标记；
   - 补/改单测（后端 jest、前端 vitest）。
3. **自测**：dev server 连 `nocodb-dev` 实测 API + UI 关键路径；后端 `pnpm test` 相关 spec 过。
4. **会审**：派遣 **5 个独立子代理**（Agent tool, general-purpose, `run_in_background`，并行），各自独立执行：
   - 集成测试：起/复用 dev server（nocodb-dev），API 实测该功能 CRUD + 边界 + 权限路径；
   - 代码复审：该功能 diff 范围内找 bug/安全/一致性问题；
   - **相互隔离：禁读他路报告与历史 r* 归档；只读 TASK.md、仓根 AGENTS.md、源码。**
   - 报告格式：`PASS` 或 issues 列表（`文件:位置:问题:建议`）；禁风格类意见。
5. **裁决**：≥2 路同一 error = 实际违反必修；单路属实经实测验证也修（不入计数）。修复后开新一轮（5 路重派）。
6. **pass 条件**：连续 **3 轮 0 error**。
7. **收尾**：归档 5 路报告为 `.work/ee-ce/r<N>-f<NN>-<agent>.md`；更新 GOAL-STATE + `.work/TODO.md`；commit（Conventional Commits，body 含 what+why+同步了哪些 md）。

## 验收清单（每功能通用）

- [ ] UI：菜单/表单项可见可用，无 upgrade 弹窗/占位空壳
- [ ] API：CRUD 全路径在 nocodb-dev 实测通过
- [ ] 权限/边界：无权限角色、非法输入、EE limit 场景行为合理
- [ ] 后端相关 jest spec 通过；前端相关 vitest 通过
- [ ] 无 `console.error` / 服务端 500 残留
- [ ] 5 子代理会审连续 3 轮 0 error
- [ ] GOAL-STATE / TODO.md / 本文件状态同步

## 安全阀

- **距上一 error 轮 >5 轮仍未达成连续 3 轮 0 error**，或**同类问题连续 3 轮未消除** → 停该功能，升级人工（记入 GOAL-STATE）。
  （2026-09-12 修订：原「总轮次 >5」字面执行会使「连续 3 轮 0 error」在 R6 必然超限，数学上不可达；改为以上一 error 轮为基准计数。）
- 会审中外部限制（网络/E3 类）有诊断证据 + 待办 = 合规未完成，不打断计数。

## 环境速查

- DB：`qnap.elf-balance.ts.net:5432` db=`nocodb-dev`（凭证：Infisical KDL `DB_*`；**严禁 `nocodb` 生产库**）
- 后端 dev：`.work/ee-ce/dev-backend.sh`（运行时拉凭证）；端口 8080
- 前端 dev：`cd packages/nc-gui && pnpm dev`；端口 3000
