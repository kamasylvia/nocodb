你是 NocoDB CE-EE fork 的 F09 Sync data **P4 生命周期 R3 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r2-p4-lane-prompt.md`（P4 验证范围全继承）与 `.work/ee-ce/r2-p4-lane3.md`（R2 error 报告，作对照）。审查基线 = 840c4218aa（R2 修复批）；后端 :8080 运行修复后 dist（pid 38535）。

## R3 重点：R2 error 修复回归（活体）

1. **v3 LTAR 通道守卫**（R2 lane3 E1）：editor 对 synced 镜像 `POST/DELETE /api/v3/data/:modelId/links/:colId/:rowId` → **422**（R2 症状 200/201 注入不复现）；owner 合法路径不受误伤；junction 配对不变；引擎 raw-knex 通道无 bypass
2. **P1-P4 全矩阵站位**：三层 link sync 全链（selected_fields 含 link）、updateSync link 级联（keep/加/删/null/[]）、双 shadow 共享、mark_deleted 两档一致、窗口 delete 收敛（Syncing/paused catch-up 全量 pass 含 sweep）、paste 纯标量全链 + paste+link 400、AUTO 双档、E1 六格、ACL、守卫链、UI 活体（向导三层/树菜单/删除流/editor 卡 gate/zh-Hans 弹窗）

## 纪律（同 R2）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p4r3lN-*；camoufox session f09p4r3lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r3-p4-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
