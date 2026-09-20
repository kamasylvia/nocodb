你是 NocoDB CE-EE fork 的 F09 Sync data **P4（LTAR 关系同步三层）R1 会审**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/f09-p4-impl-report.md`（设计 §1-8 + 实现记录 §9——本轮主对照）、`.work/ee-ce/f09-research.md` §5.1（Main/LinkedShadow/Junction SDK 语义）与 §7 P4 节、`.work/ee-ce/r3-p2-lane-prompt.md`（P1-P3 站位范围继承）。审查基线 = 43357b7c77（P4 实现批）；:8080 已运行 P4 dist（pid 29915）。

## P4 验证范围

1. **三层构建**：selected_fields 含 mm link 字段 → createSync 成功（不再 400）→ 主镜像 link 列 + LinkedShadow 镜像 + junction 三表齐（mapping role 语义正确）；junction updateSynced(true) 只读语义；includeM2M 可见性
2. **数据同步**：full-create/full-resync 下 junction RemoteId 配对写入（parent+child 键控）、shadow upsert+sweep、源 link 变更 relink/unlink 传播；直写 junction 422 守卫
3. **realtime 交互**：link 变更 → full-resync 简化档（已批）；标量 incremental 无回归（P3 不破）
4. **selected_fields 传播**：加 link 字段 → 三层级联建；删 → removeSyncedLinkFieldDropsJunctionShadow 级联（junction→shadow 引用计数）
5. **deleteSync/detach**：role 排序级联清理 / 三表全转正（sync 建的表全保留）
6. **P1-P3 全矩阵站位**：标量 sync 全链、paste、AUTO 双档、窗口收敛、E1 六格、ACL、守卫链、UI 活体
7. **声明遗留核验**（impl-report §9 五条逐条核对是否与实现一致）

## 纪律（同 P3 轮）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p4r1lN-*；camoufox session f09p4r1lN；UI/API 账号分离；测试数据全前缀测完删；质量门 tsc 0 + jest Fork 47/47 + Vite URL；报告 `.work/ee-ce/r1-p4-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
