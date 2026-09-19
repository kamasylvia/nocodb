你是 NocoDB CE-EE fork 的 F09 Sync data **P3 生命周期 R4 站位回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r3-p3-lane-prompt.md`（P3 验证范围全继承：窗口 delete 收敛、Convert 确认弹窗、realtime 全链、AUTO 双档、P1/P2 全矩阵）。审查基线 = 8de55d0b24（R3 后零代码功能变更，仅 i18n 键补齐与注释清理）；后端 :8080 运行修复后 dist。

## R4 增量（R3 小修收尾验证）

1. **zh-Hans 键**：Convert 确认弹窗标题/按钮在中文界面显示「转换为普通表」（不再回英文）
2. **站位全回归**：R3 同规格（窗口 delete 收敛三腿、paste 全链、AUTO 双档、类型漂移、detach、resync 复检、ACL、守卫链、UI 活体）

## 纪律（同 R3）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p3r4lN-*；camoufox session f09p3r4lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r4-p3-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
