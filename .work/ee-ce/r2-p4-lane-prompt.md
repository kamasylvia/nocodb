你是 NocoDB CE-EE fork 的 F09 Sync data **P4（LTAR 三层）R2 修复回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r1-p4-lane-prompt.md`（P4 验证范围全继承）、`.work/ee-ce/r1-p4-lane3b.md` 与 `.work/ee-ce/r1-p4-lane4b.md`（R1 error 报告，作修复对照）、`.work/ee-ce/f09-p4-impl-report.md` §10（修复批自述）。审查基线 = 5368ef1366（R1 修复批）；后端 :8080 已运行修复后 dist（重建自工作树）。

## R2 重点：R1 四大族修复回归（活体）

1. **updateSync link 级联重写**：keep-link PATCH → 三层不拆毁（列 id 不变、数据保留、无 500）；**结构变更后自动 full-resync 回填**（junction 配对恢复，R1「静置 junction=0」不复现）；null = 全字段含 links；`[]` → 400
2. **双 shadow 共享**：同批双 link 加腿 → 1 shadow（共享）+ junction 引用正确；重命名/单删不影响被保留 link 引用的 shadow
3. **LTAR 通道守卫**：`assertLinkWriteAllowed` 五入口（addChild/removeChild/addLinks/removeLinks/reorderLink）——editor 对镜像 link 列注入/解除 → 422；audit-only replay 放行；引擎 raw-knex 通道无 bypass 需求（防环不破）
4. **paste+link 拒收**：paste createSync selected_fields 含 link → 400（i18n `msg.warning.syncPasteLinkUnsupported` 中英文）；paste sourceSchema 不列 link 列；纯标量 paste 不误伤
5. **deleteSync 守卫**：主镜像删除失败 → sync 行保留 + 错误上抛（无僵尸）
6. **mark_deleted 一致性**：incremental flag 行 junction 配对清理（两档统一）
7. **P1-P3 全矩阵站位**：标量 sync 全链（P3 incremental/catch-up 不回归——全量 pass 含 sweep）、paste 纯标量、AUTO 双档、E1 六格、ACL 十一端点、守卫链、realtime 全链（七 tap）、UI 活体（向导三层 link 建同步、树菜单三态、删除流、editor 卡 gate、zh-Hans）

## 纪律（同 R1）

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p4r2lN-*；camoufox session f09p4r2lN；UI/API 账号分离；测试数据全前缀测完删；质量门 tsc 0 + jest Fork 60/60 + Vite URL；报告 `.work/ee-ce/r2-p4-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
