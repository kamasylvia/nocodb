你是 NocoDB CE-EE fork 的 F09 Sync data **P3 生命周期 R2 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r1-p3-lane-prompt.md`（P3 验证范围全继承）、`.work/ee-ce/r1-p3-lane1.md` 与 `.work/ee-ce/r1-p3-lane4.md`（R1 两份 error 报告，作修复对照）。审查基线 = 27efcca491（R1 修复批）；后端 :8080 运行修复后 dist（pid 50994，进程晚于 dist mtime）。

## R2 重点：R1 两 error 族修复回归（活体）

1. **E-bulk 修复**：afterBulkInsert 已 tap（同 !synced 守卫族）——realtime sync 源表**数组体插多行**（v2 POST 数组）→ 亚秒级传播进镜像；粘贴/CSV 同形态；R1 症状（零传播）零复现；afterBulkRestore（软删恢复）同样传播
2. **E-syncing 修复**：loadRealtimeTargets 已去 status 过滤（全状态可见 + role='main'）——**Syncing 窗口**（大表 resync 中）源插/改/删 → 事件进 markSkipped → 当轮结束 enqueueCatchUpIfNeeded 补齐（无消失扫描的全量 upsert）→ 数据最终一致；**paused 窗口**事件 → resume 时自动补齐（lane4 run5 场景：paused 三写 → resume → 全部追平）
3. **E-watermark 修复**：补齐不再走 RemoteUpdatedAt where 查询（422 源）——改无扫描全量 upsert（幂等）；插入行（updated_at=NULL）经此路径可达
4. **camelCase 别名**：PATCH `selectedFields`（camelCase）→ 生效非 no-op
5. **P1+P2+P3 站位全继承**：paste 全链、类型漂移、detach、resync 复检、六格、ACL、引擎 e2e、守卫链、UI 活体

## 纪律（同 R1）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p3r2lN-*；camoufox session f09p3r2lN；测试数据全前缀测完删；报告 `.work/ee-ce/r2-p3-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
