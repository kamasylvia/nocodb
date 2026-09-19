# R3 P3 lane2 — 修复回归独立审查报告（窗口 delete 收敛 + Convert 确认弹窗）

**结论：PASS — 0 error + 3 minor**

- 审查员：lane 2（账号 f09p3r3l2-api / f09p3r3l2-ed，camoufox session f09p3r3l2）
- 基线：5d25acfc51（R3 修复批）= HEAD；:8080 = pid 75970 运行 `~/.nocodb-run/packages/nocodb/dist/main.js`（dist mtime 09-20 02:10 < 进程启动 02:21 < commit 02:24），健康 200。全程零构建/零重启/零 psql/零源码改动。
- 活体脚本：`.work/ee-ce/f09p3r3l2-setup.sh`、`f09p3r3l2-run1..4.sh`；结果 `/tmp/f09p3r3l2-run1..4.txt`；后端日志 `/private/tmp/nocodb-internal.log` 按自有 sync id（tss0z32utz3bsekq7 / tsswza2ca6ufcgjkh / tssqfwpa5cini41kj）归因。

---

## 0. R3 重点 1：窗口 delete 收敛（R2 四路同判 E1' 修复回归）——成立

修复形态源码确认：processor 无 touched ids 的 incremental run 删除原 no-sweep 全量 upsert 分支，落入 FULL pass（upsert + disappearance sweep，`table-sync.processor.ts` R3 diff）；realtime.ts 死代码（watermarkStart/WATERMARK_OVERLAP_MS）删除。

| 场景 | 活体证据 |
|---|---|
| **realtime 基线（删/改/bulk 传播）** | 源 DELETE a3 → 镜像 RemoteDeleted=true **0.5s**；PATCH a1 Qty=99 → **0.4s**；数组 bulk POST 3 行 → 3/3 **0.4s**（run1 A1-A3） |
| **paused 窗口三写（R2 决定性场景重演）** | freeze → PATCH b1=111 / POST w_ins / DELETE b2 全 200 → 3s 零泄漏（w_ins 缺席、b1 旧值、b2 未标）→ resume → 自动 catch-up（日志 02:32:55 jobblmxidy8cyo5yz，`[incremental]: source rows=5 inserts=1 updates=6`，updates=6 = 5 upsert + **b2 sweep 标记**）→ **b1=111 ✓ + w_ins 进 ✓ + b2 RemoteDeleted=true ✓ 三腿全追平，零手动 resync**（run2 B1-B3） |
| **Syncing 窗口（大表 resync 在飞）** | 3011 行源表；POST resync → 轮询捕获 status=syncing（窗口确证打开）→ 窗口 PATCH a1=12345 / POST c_win / DELETE c0002 全 200 → resync run 结束 catch-up（02:37:17 job1qzf05wsz8jly2，`inserts=1 updates=3013`）→ **c_win 出现 ✓ + c0002 ghost RemoteDeleted=true 消失 ✓**；live(RD!=true)=3011 == source=3011 ✓（run3 C1-C4） |
| **幂等复跑** | freeze/resume 空转触发再次 catch-up → 行数 7→7 稳定；seed 风暴（6×500 行 bulk）后 1 增量 job + 1 次 catch-up 全量 pass 收敛、无重复行（run2 B4 + 日志 02:34:35-48） |
| **守卫链** | 镜像直插/直改 400（run1 A4）；静默窗 8s 零 churn（run1 A5）；我名下 3 个 sync id 日志 `run failed`/`enqueue failed` = 0 条 |

## 1. R3 重点 2：Convert 确认弹窗（lane5 minor 修复回归）——成立

UI 活体（camoufox session f09p3r3l2，owner 登录，dst base 树上 synced 表）：

1. 树行「...」菜单（`.nc-tbl-context-menu`）→ Sync 菜单含 `table-sync-menu-sync-now/freeze/convert/delete` 全项 → 点 Convert → **确认弹窗出现**（`.nc-table-sync-convert-modal`，title "Convert to regular table"，正文 `f09p3r3l2-ui-sync — "f09p3r3l2-ui-sync"`，**Cancel/Convert 双按钮** testid `table-sync-convert-cancel/confirm` 齐备）。
2. **Cancel**：弹窗关闭、零动作（表留在树、后端 sync 无变化）。
3. **Esc**：弹窗关闭、零动作（owner API 终审 sync3 `{"status":"active","deleted":false}` 未删）。
4. **Convert 确认**：弹窗关、表留树、行内 sync 图标消失（UI eval 断言 0 个 sync svg/img）；后端复核 sync 记录 404、`synced:false`、行数全保留——与 detach API 全链活体一致（run4 D4：detach 200 → sync 404 → synced=false → 3014 行保留 → 镜像可写 200 → 源改动不再传播）。

## 2. 质量门

- `npx tsc --noEmit` exit 0。
- jest Fork 桶 3 suites **44/44**（table-syncs.Fork.spec 含 R3 更名后的 full-pass-with-sweep 用例）。
- Vite URL 编译法 4/4 = 200 真真 transform 产物（SyncMenuOptions.vue 36KB、CreateNewSync.vue 59KB、useEeConfig.ts 60KB、useTableSync.ts 7.6KB）；SyncMenuOptions 产物内 `isConvertConfirmOpen` ×7 处——R3 弹窗代码在 dev 前端产物中。

## 3. P3 全站位继承（抽查）

- **selected_fields camelCase 别名**：PATCH `{"selectedFields":["Title","Status"]}` → GET 持久化同值 ✓；snake_case `selected_fields` 恢复三列 → resync 后镜像列含 Qty（终态列实证）。注：减列的中间态因探针 table-meta 路由错（columns 取空）未直接观测，减列效果由恢复后列集与 R2 已验链路间接支撑。
- **ACL**：editor 对 freeze/resync/detach/PATCH/DELETE 全 **403**；PATCH 后 sync title 未被改动；另证 editor 读 sync 详情/列表也 403（信息面收口）。
- **paste/CSV 形态**：数组 bulk POST = paste 同通路，0.4s 传播（run1 A3）+ 500 行数组 ×6 全量 200（run3 C0）。
- **AUTO 双档 / 类型漂移 / E1 六格**：本轮未单独重跑（非 R3 修复面，R1/R2 已过，dist 同源未回退——processor diff 仅 catch-up 分支）。

## 4. Minor（3）

- **M1 dist 与 HEAD 源码部分错位（交付完整性，非功能缺陷）**：运行 dist（mtime 02:10）含 processor sweep 修复（特征串在 + 三重活体确认），但 **table-sync-realtime.ts 部分为 R2 版**——R3 新增的 `claim missed (syncing/paused) — marked for catch-up` debug 日志在 dist **0 处**（grep 实证，仅有 R1 旧注释 2 处）。活体窗口期间 catch-up 确被触发（= claim miss + markSkipped 必然发生）而日志 0 条「claim missed」。commit message「claim misses now log」在运行产物上不成立——推断 debug 行在 02:10 构建后、02:24 commit 前补入且未重新构建。行为正确性无损；R2 lane3 M3 的可观测性诉求仍未真正部署。建议 orchestrator 安排重新 hot-sync，下一轮验证该 debug 行输出。
- **M2** resync POST 响应体回显完整 BullMQ job 序列化（含用户 xc-auth JWT、整个 req/socket 对象，run3 C1 原始响应观测）——敏感物料进响应体与 job 存储/日志面。自己的 token 回给请求者、风险低，属纵深防御缺失；建议响应收敛为 job id/状态。
- **M3**（R1 M1 → R2 M4 延续，未随本轮修复）`bulkUpdateAll` 计数形态不 tap → 按过滤器批量更新不传播无补齐。维持观察级 minor，本轮未活体。

## 5. 方法学注记

- 探针缺陷两处，已修正并如实归因（不记产品账）：① zsh 双引号展开 python heredoc 变量 → 6 次 POST 空数组（v2 records 对空数组各插 1 行空 Title 行——衍生认知）；② PATCH `{"Id":1}` 误指 a1（c0001 实为 Id 14）——Syncing 窗口 update 腿由 a1=12345 传播覆盖，c0001 恒为 1 属探针错目标。
- **UI 登录与 API token 互斥**：同账号 UI signin 轮换 token_version，旧 API token 即 401（两次实测咬人）——任务书「UI/API 账号分离」纪律的机理证明；后段 API 复核改走重 signin、ed 账号旁证 ACL。
- mirror `pageInfo.totalRows` 含 RemoteDeleted=true 行；live 对账须 `where=(RemoteDeleted,neq,true)`（C0 断言口径修正后 C4 过）。
- 共享 :8080 多 lane 并发（日志可见他 lane sync id 活跃）；全部结论按自有 sync id 归因。他 lane 窗口 catch-up 日志 `deletes=1` 亦为 sweep 修复生效的独立旁证。

## 6. 测试数据与痕迹

- 删除：sync3（200）、dst/src 两 base（200/200）；bases 列表 `f09p3r3l2` 残留 **0**；6 空行随 src base 消亡。sync1 已随 detach 消亡、sync2 已随 UI Convert 确认消亡。
- 保留：账号 f09p3r3l2-api / f09p3r3l2-ed（后续轮可复用；ed 全程未登录 UI）；脚本与 `/tmp/f09p3r3l2*` 结果文件。
- 源码零改动；:8080 未重启未重建；camoufox 会话已关闭。
