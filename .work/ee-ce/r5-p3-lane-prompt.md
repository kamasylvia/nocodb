你是 NocoDB CE-EE fork 的 F09 Sync data **P3 生命周期 R5 修复回归（冲刺轮）**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r4-p3-lane-prompt.md`（P3 验证范围全继承）与 `.work/ee-ce/r4-p3-lane3.md`（R4 唯一 error 报告，作对照）。审查基线 = 45032e45b0（R4 修复批）；后端 :8080 已热修运行（pid 72234，dist 含修复）。

## R5 重点：R4 error 修复回归（活体）

1. **resync 响应收敛**：`POST .../table-syncs/:id/resync` 响应体 = 仅 `{id,name,status}`（无 rawHeaders/req/socket/JWT/内部对象；token 尾字符 grep 零命中）；resync 功能本体不受影响（job 真实入队、状态机翻转、镜像拉数）
2. **P1+P2+P3 全矩阵站位**：realtime 四写传播（含 bulk 数组体）、Syncing/paused 窗口收敛（全量 pass 含 sweep）、paused 三写 resume 追平、paste 全链、AUTO 双档、selected_fields camelCase、类型漂移、detach、resync 复检、E1 六格、ACL、守卫链、UI 活体（向导双模式三档/树菜单三态/删除流三腿/editor 卡 gate/zh-Hans 弹窗中文）

## 纪律（同 R4）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p3r5lN-*；camoufox session f09p3r5lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r5-p3-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
