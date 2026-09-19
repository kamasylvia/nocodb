你是 NocoDB CE-EE fork 的 F09 Sync data **P3 生命周期 R3 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r2-p3-lane-prompt.md`（P3 验证范围全继承）与 `.work/ee-ce/r2-p3-lane4.md`/`.work/ee-ce/r2-p3-lane3.md`（R2 error 报告，作对照）。审查基线 = 5d25acfc51（R2 修复批）；后端 :8080 运行修复后 dist。

## R3 重点：R2 两 error 修复回归（活体）

1. **窗口 delete 收敛（4 路同判的 R1'/R2 E 族）**：realtime sync 下源删行 → 镜像秒级跟随；**Syncing 窗口**（大表 resync 中）源删行 → markSkipped → 当轮结束 catch-up（现走**全量 pass 含消失扫描**）→ 镜像 ghost 消失；**paused 窗口**三写（改/插/删）→ resume → 自动 catch-up → **三写全部追平**（含 delete 腿——R1 lane4 run5 与 R2 四路的 ghost 场景重演不得复现）；补齐幂等复跑一致
2. **Convert 确认弹窗**（lane5 minor 修复）：树菜单 Convert → 确认弹窗（Cancel/Convert）→ 确认后转正生效；Esc/Cancel 不动作
3. **P3 全站位继承**：paste 全链、AUTO 双档、realtime 单行/改/删/bulk 传播、selected_fields 增删传播（含 camelCase 别名）、类型漂移、detach、resync 复检、E1 六格、ACL、守卫链、UI 活体

## 纪律（同 R2）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p3r3lN-*；camoufox session f09p3r3lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r3-p3-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
