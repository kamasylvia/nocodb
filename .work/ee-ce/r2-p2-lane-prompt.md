你是 NocoDB CE-EE fork 的 F09 Sync data **P2（生命周期完备）R2 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r1-p2-lane-prompt.md`（P2 R1 任务书，六项验证范围继承）、`.work/ee-ce/f09-p2-impl-report.md`（实现自述）、`.work/ee-ce/r1-p2-lane1.md` 与 `.work/ee-ce/r1-p2-lane5.md`（R1 两路 error 报告——仅此两份历史报告允许读，作修复对照）。

## 审查基线

HEAD = 366e0b7045（R1 修复批，五 error 全修）。后端 :8080 已热同步运行修复后 dist（进程晚于 dist mtime，可 grep 特征核验）；前端 :3000 HMR 即当前源码。

## R2 重点：R1 五 error 修复回归（逐项活体）

1. **E1+E2 paste 建同步**：`POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>[, sharedViewPassword]}`（**不带 sourceTableId**，对齐前端实发形态）→ 200 建镜像 + 引擎拉数 + mapping 落 uuid/hash；R1 症状（"Shared view not found"/"no syncable columns"）不复现
2. **E3 selected_fields 减字段**：PATCH selected_fields 减列 → 200（无 500 undefined binding）→ 镜像列删 + 映射删 + resync 后数据对齐；增列 → 新列(readonly) + resync 后数据进（R1 E4：dest_column_id 落 model id 致数据永不同步——本轮须核验新列真实进数）
3. **resolveLink 密码保护**：设密视图无密码 resolve → 仅 `{passwordProtected:true}`（无 title 泄露）；对密码 → 全量坐标
4. **M3 菜单守卫**：Syncing 态树菜单 Convert/Delete 不可见
5. **P1 全矩阵回归**：E1 六格、ACL 十端点、引擎 e2e（full-create/resync/双删除策略/freeze-resume/deleteSync）、守卫链、编译门 Vite URL 法

## 纪律（同 R1）

- 只读审查：严禁修改源码（:8080 已就绪，无需任何构建/重启；异常每 60s 轮询，禁自愈）
- 隔离：禁读他路报告
- 禁 psql 提全局 super；账号 f09p2r2lN-*；camoufox session f09p2r2lN；UI/API 账号分离
- 测试数据全 `f09p2r2lN-` 前缀，测完删除
- 质量门：tsc 0 + jest Fork 桶 + Vite URL 编译检查
- 报告 `.work/ee-ce/r2-p2-laneN.md`（沙箱禁写则 stdout 全文输出文末注明待落盘）；结论头：PASS / N error + N minor
