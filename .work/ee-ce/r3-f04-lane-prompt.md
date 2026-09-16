你是 NocoDB CE-EE fork 的 F04 Manage Syncs 第 3 轮复审（R3）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r1-f04-lane-prompt.md`（完整任务书，R1/R2/R3 同规格），再读增量。

## R3 增量附录（R2 修复批回归 + 已知非问题）

- **R2 修复 commit**：resync 完成跟踪重写——`Sync/index.vue` **弃用 $poller websocket**（jobs/listen 属主门控致协作者 404 死锁 + close 回落读陈旧 store），改为 **3s 间隔 jobs-list watchdog**：`loadJobsForBase` + 显式 COMPLETED/FAILED 终态检测 + 90s 超时兜底（i18n syncsSyncTimeout）。
- **回归强测项**（本轮重点）：
  ①**owner 路径**：伪凭证触发秒败 ≥3 次——终态错误文案必须出现、严禁停留 "Syncing…"、失败后 Resync 可再点；
  ②**协作者路径**（R2 lane1 死锁场景）：creator 协作者对 **base owner 名下**的 sync 点 Resync → 面板不得死锁（watchdog 轮询 jobs 列表对协作者可用），终态/超时文案必须出现；
  ③交替多轮 resync 无卡死累积；
  ④（若可建真实凭证链路）成功路径 done 文案验证。
- **已知非问题（勿再报）**：editor 直连 settings/syncs URL 顶栏 "Manage Syncs" 标题（上游 settingsPageTitle 框架行为）；dev 库 700+ 测试账号；shared owner 账号 signin 互踢（用 lane 专属账号）；:3000 不代理 /api、双 nuxt 实例 IP 隔离；v1 bulkUpsert 500 / v1 title 寻表 404 / sharedView meta / duplicate >1000 行 / v2 upsert 旗标（上游）。
- **测试隔离纪律**：只动自己 f06lN 前缀（或任务书指定前缀）数据；严禁 psql 提全局 super（owner 直通假放行）。
- 其余全矩阵/回归/质量门要求同 R1/R2 任务书。
