你是 NocoDB CE-EE fork 的 F09 Sync data **P2 生命周期 R4 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r3-p2-lane-prompt.md`（验证范围全继承）与 `.work/ee-ce/r3-p2-lane5.md`（R3 唯一 error 报告，作对照）。审查基线 = 253c3b6ee5（R3 修复批）；后端 :8080 已运行修复后 dist（进程晚于 dist mtime）。

## R4 重点：R3 发现修复回归（活体）

1. **editor Overview 卡**：editor 开空 base → Overview「NocoDB Sync」卡**不可见**（R3 lane5 实测可见；修复 = 卡加 isUIAllowed('sourceCreate') gate，253c3b6ee5）；creator 仍可见可用
2. **hash 形共享 URL**：`…/#/nc/grid/<uuid>` 形态 resolveLink/sourceSchema/createSync → 200（R3 lane4 M-1 症状 400 不复现）
3. **响应凭据剥离**：getSync/listSyncs 响应**不含** source_uuid/source_password_hash（R3 lane2 发现）
4. **漂移日志**：后端日志漂移传播行呈「旧值 -> 新值」（M-2）
5. **P1+P2 全矩阵站位**：paste 全链、selected_fields 增删传播（增列真实进数）、类型漂移、detach、resync 复检、E1 六格、ACL 十一端点、引擎 e2e、守卫链、UI 活体（向导双模式/树菜单三态/删除流三腿）

## 纪律（同 R3）

只读审查禁改源码；禁 dev-backend*.sh/pkill/自愈/psql super；隔离禁读他路报告；账号 f09p2r4lN-*；camoufox session f09p2r4lN；UI/API 账号分离；测试数据全前缀测完删；质量门 tsc+jest+Vite URL；向导 SFC = components/project/Action/CreateNewSync.vue。报告 `.work/ee-ce/r4-p2-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
