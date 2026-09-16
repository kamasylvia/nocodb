你是 NocoDB CE-EE fork 的 F04 Manage Syncs 第 4 轮复审（R4）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r1-f04-lane-prompt.md`（完整任务书，R1-R4 同规格），再读本增量。

## R4 增量附录（R3 修复批回归，commit b6c95cb3ac）

1. **watchdog 卸载清理**：Sync/index.vue 的 watchdog interval 现登记于 watchdogTimers 并在 onUnmounted 全清——验证：触发 Resync 后立即导航离开（如切 Data tab），≤90s 后无孤儿轮询（可通过面板重进后行为正常 + 代码审确认）。
2. **二次 resync 反馈**：一个 sync 在同步中时再点其 Resync → info toast "Syncing…"（不再静默）。
3. **90s 超时文案**：不再提及 "job list"（i18n en/zh 双份更新）。
- **已知非问题沿袭 R3 清单**：成员下拉"8 条截断"（不存在）、editor 顶栏标题（上游框架）、dev 库 700+ 测试账号、v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行 / v2 upsert 旗标（上游）、FAILED 详情恒泛型（上游 setJobResult 零调用）。

## 流程纪律（R3 教训入库）
- **camoufox 必须用 lane 专属 --session 名**（default 会话被并行路互踩）。
- **严禁 psql 提全局 super**（owner 直通假放行）；账号只建/动自己前缀。
- UI/API token 互踢：每路自建专属账号。
- 其余全矩阵/质量门要求同 R1 任务书。
