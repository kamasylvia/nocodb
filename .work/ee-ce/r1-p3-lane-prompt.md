你是 NocoDB CE-EE fork 的 F09 Sync data **P3（incremental/realtime + AUTO 解锁）R1 会审**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/GOAL-STATE.md`「F09 P2 PASS」节末尾 **P3 realtime 设计定案**、`.work/ee-ce/f09-p3-impl-report.md`（实现自述）、`.work/ee-ce/r3-p2-lane-prompt.md`（P2 站位范围继承）与 `.work/ee-ce/f09-research.md` §7 P3 节。审查基线 = f6a9314b5e（P3 实现批）；:8080 已运行 P3 dist。

## P3 验证范围（API 实测 + 引擎活体 + 源码审）

1. **realtime 全链**：createSync `syncTrigger:'realtime'` → 200 建镜像；源表插/改/删行（API 写）→ 亚秒~秒级 incremental job 自动跑（affectedIdsBySource 按 pk 拉）→ 镜像跟随（插/改进、删按 on_delete_action delete 删 / mark_deleted 置 flag）；源写同步环验证：镜像表作源被 tap 抑制（`!model.synced` 守卫）——引擎写 DEST 不触发第二轮
2. **Syncing 投递跳过 + 补齐**：长跑（大表 resync）窗口内源再改 → CAS miss 跳过 → 当轮结束后补齐水位 job → 数据最终一致
3. **incremental 水位**：空 affectedIds 增量 = RemoteUpdatedAt 水位拉（last_synced_at−30s 重叠）；源表无 LMT 列 → 回退全量；水位拉跳过消失扫描（部分拉取不误删）
4. **AUTO 解锁**：blockTableSyncAuto=false 生效；向导 Automatically/Manually 单选可用（realtime 默认建）；manual sync 行为不变（Sync now 全量）；realtime sync 无 Sync now 需求（自动）但 API resync 仍可用
5. **P1+P2 全矩阵站位**：paste 模式（uuid+密码凭据）、selected_fields 增删传播、源列类型漂移、detach 转正、resync 复检、E1 六格、ACL 十一端点（+realtime 建的 sync 同权）、引擎 e2e、守卫链、UI 活体（向导双模式三档、树菜单三态、删除流三腿、editor 卡 gate）
6. **质量门**：tsc 0 + jest Fork 桶（44/44 基线）+ Vite URL 编译法

## 已知遗留（不重复报，除非升级）

级联镜像止于一跳（fork 简化）；补齐标记单进程内存态（CE fallback queue 同进程）；水位依赖源 LMT 列（无则回退全量）；paste resync 不复验 hash（EE 语义未定）；Convert 后 grid 瞬空白已修（getMeta force + loadViews）。

## 纪律

只读审查禁改源码；:8080 已就绪禁构建/重启/dev-backend*.sh/pkill/自愈（8080 异常 60s 轮询×3 才记 E3）；禁 psql 提全局 super；隔离禁读他路报告；账号 f09p3r1lN-*；camoufox session f09p3r1lN；UI/API 账号分离；测试数据全前缀测完删；报告 `.work/ee-ce/r1-p3-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
