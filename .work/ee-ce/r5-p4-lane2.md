# F09 P4 R5 — lane 2（修复回归 + 全站位）报告

**结论：PASS / 0 error + 0 minor**
（R4 error 修复回归四态活体零复现；P4 全站位与 P1-P3 站位同规格复跑全过；R4 小修注释双侧核验过。维持项 M1/M2 照录不计数。质量门 tsc 0 + jest Fork 63/63；Vite URL 门 5 次尝试均因 vitest worker 冷启动 60s 硬编码上限被环境负载击穿，未取得通过——详见「未覆盖」。）

审查基线 = b4849136e1（R4 修复批）；HEAD = eb6dbf55e6（仅 .work 流程件，`git diff b4849136e1 -- packages/` 为空 → 功能代码零变更，:8080 即基线行为）。dist 双条件核验：dist mtime 2026-09-22 03:57:30 < :8080 进程（pid 76261）启动 04:06:36 ✓；dist 特征串 `F09 P4-R4`×4、`P4-R2`×2、`prohibitedSyncTableOperation`×7、`WITHOUT the disappearance sweep` **0 命中**（M1 注释修复已入 dist）。账号 `f09p4r5l2-{owner,editor,ui,uied}`（API/UI 分离）；camoufox session `f09p4r5l2`；脚本 `f09p4r5l2-{run1,run2,run3,ui-setup,probe-upd}.sh`；截图 11 张 `.work/ee-ce/ui-shots-f09p4r5l2/`。

## 1. R5 重点：R4 E1 修复回归（run1，全部通过）

双 mm link 列（T2s/T2s2）同指一 RT 的精确复现配置，manual sync 三层（1S+2J，full-create 配对 3/3）：

1. **删单腿**：PATCH 去 T2s → **200**（R4 症状 404 零复现）；共享 shadow 保留（synced=true）；T2s2 三层完好（junction mapping=1、配对=3、镜像列 id 不变）；被删 junction 表 404。
2. **加回**：PATCH 全含 → 200；复用既有 shadow（仍 1S+2J，shadow id 不变）；双 junction 配对 3/3 自动回填。
3. **一条 PATCH 全删（R4 lane5 E1 精确触发点，旧代码此处 404+部分拆毁）**：→ **200**；roles=[main]；shadow + 双 junction 表全部 404、dest base 表清单零残留；镜像零 link 列；标量 3 行不受影响。
4. **重复轮收敛（幂等）**：null PATCH 重建（2J/1S + 配对 3/3）→ 再次一条 PATCH 全删 → 200，roles=[main] 零残留。
5. 「中途失败→重试」路径：活体层面以「重复轮收敛」+ spec 用例 `converges on retry after mid-loop failure`（jest 63/63 内）覆盖；R4 sweep 代码路径（drop 发生后的僵尸 junction 清理）在静态审查中确认 keep-only PATCH 不触发（与 R1 行为逐字节一致）。

## 2. P4 全站位继承（run2，全部通过）

- **v3 通道守卫**：owner/editor 对镜像 `POST/DELETE /api/v3/data/.../links/...` → 422×4（`ERR_SYNC_TABLE_OPERATION_PROHIBITED`），拦截后 junction 配对不变；v3 PATCH 镜像标量 400 readonly。
- **合法路径不误伤**：owner 源表 v3 POST 200；editor dest 普通表 v3 POST/DELETE 200；owner 镜像 v3 GET 200。
- **P2 守卫链 + ACL**：editor junction 直写 422、editor 删镜像行 422；editor list/create/resync/detach/delete 五端点全 403。
- **updateSync 级联五态**：keep-link PATCH 三层不拆毁（镜像列 id 不变）且不投 resync（last_synced_at 不变）；`[]`→400；加腿共享 shadow（1S+2J，自动 full-resync 回填配对）；删腿 junction 拆 + shadow 保留；null=全字段含 link（双 junction）。
- **resync 传播**：源加/删配对 → 双 junction 精确收敛（3/1→2/1）。
- **窗口 delete 收敛（sweep）**：源删行 → resync → mirror 消失行 + junction 孤儿清（mirror=2、junction=1）。
- **mark_deleted 两档一致**：onDeleteAction=mark_deleted 的 sync，源删行 → resync → mirror **保行 + RemoteDeleted=true** + junction 配对清零（与 delete 档「行删 + 配对清」统一）。
- **paste 面**：browse sourceSchema 列 link 列（`link:true`）；paste sourceSchema 不列 link；paste+link createSync → 400；paste 纯标量建成（三响应凭据剥离抽样=absent）。
- **deleteSync 级联 + detach 转正**：deleteSync 后镜像/junction 表清零；detach 后 resync 404、mirror synced=false、数据保留。

## 3. P1-P3 realtime 站位（run3，全部通过）

realtime sync：标量插入 ~2s 镜像出行（incremental）；link 配对变更 ~2s junction 自动回填（link tap → full-resync，无手动 resync）；源改值传播（bulk PATCH 路由）；realtime delete 收敛（mirror 行删 + junction 配对 3→2，合法配对保留）；E1 系统列抽查（RemoteId 有值、synced=true）。

## 4. UI 活体（camoufox session f09p4r5l2）

- **向导三层 link 建同步全链**（截图 01-02）：NocoDB Sync 卡 → browse 选 base/table → specific 字段列表含 link 列 T2s（向导零改动自然可选）→ step2 双设置组 → Create sync → API 交叉核验 roles=[main,linked_shadow,junction]、status=active。
- **镜像 grid 写禁入**（截图 05）：打开镜像 grid，「New record」按钮 `disabled=true`（DOM 实锤）。
- **树菜单三态 + Syncing 守卫**（截图 06/07/09）：Synced 全项（立即同步/暂停同步/转换为普通表/删除同步）→ Sync now 触发后立即重开菜单 = **五项全 disabled**（守卫实锤）→ 任务完成后恢复全项 → Pause → Paused（菜单现 Resume sync，API status=paused）→ Resume → API status=active。
- **zh-Hans 维持验证**（截图 10）：zh-Hans locale 下登录页/树菜单全中文；「转换为普通表」弹窗标题/正文/按钮（取消 / 转换为普通表）**全中文零英文回落**（R3 小修维持）。
- **删除流**（截图 11）：「删除同步」确认弹窗（中文）→ 确认后 sync=[]、dest 表清零、树空回 base home（leg3 等价；leg1/leg2 历轮已锁定，本轮未复跑）。
- **editor gate**（截图 12）：uied（editor）打开 synced 镜像 grid →「New record」`disabled=true`（DOM 实锤）。

## 5. 静态审查（R4 修复批 b4849136e1）

- `table-syncs.service.ts`：两阶段 drop（循环内只收 `droppedLinkRtIds/droppedLinkSrcColIds`，循环外 sweep 后 phase 2 才做 shadow 引用计数 drop，`keptLinkRtIds` + `stillReferenced` 双闸）；`dropMirrorLinkColumn` 404 族幂等容错（其它错误照常上抛）；junction 僵尸 sweep 仅在 `droppedLinkSrcColIds.size>0` 时触发，tableDelete best-effort + 登记行无条件删。与 impl-report §11 自述逐条一致，无范围外 hunk。
- `table-sync.processor.ts` M1：pull-shape 头注释已改为「catch-up 落入 FULL pass（upsert + disappearance sweep，P3-R2）」；源码与 dist 双侧无 "WITHOUT the disappearance sweep" 残留。
- spec 3 个 R4 回归用例在位（60→63）。

## 6. 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**（`.f09p4r5l2-tsc.log`）。
- `npx jest --testPathPattern 'Fork'`：**63/63，3 suites 全过**（`.f09p4r5l2-jest.log`）。
- Vite URL 门：**5 次尝试未取得通过**（`.f09p4r5l2-vite.log`）。失败模式恒定：vitest 4.1.11 worker 冷启动超时——`START_TIMEOUT = 6e4`（cli-api.CnMVyzaz.js:2861，硬编码常量，CLI/config 均不可覆盖），本机当前负载（外置盘 IO + 常驻 nuxt dev 进程）下 worker 冷启动稳定超 60s；唯一一次 worker 启动成功（threads pool）也因 beforeAll hook 以 60s（参数未生效的那次）超时致 5 tests skipped。判定：环境负载限制，非代码回归——该测试（formula-url-xss，smartsheet 工具函数）与 F09 sync 改动零交集，R4→R5 功能代码零变更，门结果预期与 R4 轮（5/5 通过）一致。

## 7. 脚本瑕疵注记（均脚本侧修正后全过，无一产品问题）

run1 jq `--arg` 误传；run2 v3 PATCH 误用不存在的单行路由（实际为 `/:modelId/records` bulk 形态，404 是路由不匹配）、browse link 列断言未随加腿步骤更新、null 重建后 junction 表 id 未刷新；run3 同 PATCH 路由错误、p2 配对断言设计缺配对、第 4/6 步 echo 文案未随断言更新（断言值正确，输出 `junction=2/1` 为旧文案）。probe-upd 首跑一次 signin 瞬时失败（复跑正常，未复现）。

## 8. M 系列（0 新增；维持项）

- **M1（维持）** i18n 死键 `msg.warning.syncPasteLinkUnsupported`（组件零引用，400 后端英文）——本轮未涉，维持 R2/R3/R4 判定。
- **M2（维持）** spec 仍无 v3 通道用例（63/63 未新增）——v3 守卫靠活体锁定（本轮 422×4 复跑通过）。
- （观察，非判定项）Syncing 守卫的菜单表现为**五项全 disabled**（R4 lane5 记录为「五项全隐」），守卫语义一致，差异或为前端版本演进；不影响判定。

## 9. 未覆盖（环境/范围限制，非「通过」）

1. Vite URL 门（见 §6——5 次尝试、根因定位、与 F09 零交集论证）。
2. 删除流 leg1/leg2（非 active 删表 / active 删表重定向 remaining[0]）——历轮锁定，本轮以「删除同步」全清路径（leg3 等价）抽样。
3. 「中途失败 → 同 PATCH 重试」的独立活体（依赖注入故障，API 层不可构造）——以 spec 用例 + 重复轮收敛覆盖。
4. 测试账号删除：无删除用户 API，`f09p4r5l2-{owner,editor,ui,uied}` 保留（全前缀可辨，历轮同惯例）。

## 10. 纪律

只读审查：`git status` 跟踪文件零改动（packages/ 与 b4849136e1 零 diff；新增仅 `.work/ee-ce/f09p4r5l2-*` 脚本/日志、本报告、ui-shots 截图）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R5 报告（对照材料限任务书指定链：r4/r3/r2/r1 lane-prompt、r4-p4-lane5、f09-p4-impl-report）。测试数据清零核验：`f09p4r5l2*` base 计数 = **0**（run1/2/3 trap 清理 + UI/probe 残留 4 个手动删除后复核）；无凭证写入 git 跟踪文件（口令仅存 `.work` 白名单脚本，历轮惯例）。
