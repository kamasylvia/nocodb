你是 NocoDB CE-EE fork 的 F09 Sync data **P4 生命周期 R4 站位回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r3-p4-lane-prompt.md`（P4 验证范围全继承：v3 通道守卫、三层 link sync、updateSync 级联、窗口收敛、P1-P3 全矩阵）与 `.work/ee-ce/r3-p4-lane3.md`（上轮对照）。审查基线 = 840c4218aa（R3 后零代码功能变更，仅 i18n/注释清理与流程件）；后端 :8080 运行修复后 dist。

## R4 = 连击 2/3 冲刺轮：同规格站位回归 + R3 小修收尾验证

1. R3 全部验证项同规格复跑（v3 通道守卫活体、三层 link sync、updateSync 级联、窗口收敛、P1-P3 全矩阵、UI 活体）
2. R3 小修验证：zh-Hans `labels.convertToRegularTable` 弹窗全中文（8de55d0b24 已落）；processor/realtime 注释腐化清理后无新问题
3. 已知遗留勿重复报：i18n 死键 `msg.warning.syncPasteLinkUnsupported`（组件零引用，400 后端英文）、spec 缺 v3 通道用例（活体已锁定）、createSync 蛇形 `selected_fields` 不认（API 健壮性）、源 link 列删除孤儿、bulkUpdateAll 不 tap、paste resync 不复验 hash、afterBulkRestore CE 无调用方

## 纪律（同 R3）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p4r4lN-*；camoufox session f09p4r4lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r4-p4-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
