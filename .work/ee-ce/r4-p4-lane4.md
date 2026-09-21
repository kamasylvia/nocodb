# F09 P4 R4 — lane 4（引擎重点路，ZCode subagent）报告

**结论:PASS / 0 error + 3 minor**

审查基线 = 840c4218aa（R2 修复批）;**R3→R4 零功能变更确认**:`git diff 840c4218aa..HEAD --stat` 仅 `.work/ee-ce/r3-p4-lane-prompt.md`（流程件）;zh-Hans/注释清理 8de55d0b24 落在基线内。:8080 存活（`GET /api/v1/health` → 200,pid 38535,与 R3 报告同 pid 未重启）。**dist 双条件核验通过**:pid 启动 01:41:12 > `~/.nocodb-run/.../dist/main.js` mtime 01:34:28,且 dist 内 grep 守卫特征串 `Link operations (link / unlink / reorder) are prohibited` ×2、`manage the links in the source table` ×2 ⇒ 活体打的是含 R2 E1 修复的 dist。账号 `f09p4r4l4-{api,ed,ui}@review.local`（UI/API 分离;owner=api）;camoufox session `f09p4r4l4` 已关闭。脚本:`.work/ee-ce/f09p4r4l4-run{1,2,3,4}.sh` + `/tmp/f09p4r4l4-run*.txt` 输出。

## 1. 引擎三层 link sync 全链（活体,全部通过）

- **createSync 含 link**（`["Title","Qty","RtLinks"]`,browse+realtime）→ active;三层 mapping 齐（main + linked_shadow + junction,junction `source_table_id=null` 语义正确）;full-create 后 mirror=3 / shadow=3 / junction=0（源侧无配对）;shadow 内容 = rt1,rt2,rt3。
- **junction 配对 recompute 双向传播**:源 v2 建 3 对（r1-rt1, r2-rt1, r2-rt2）→ ~15s junction=3;源解链 r2-rt2 → junction=2;重加 → 3。镜像 link 列 nested 读逐对核:r1→1、r2→2 ✓。
- **静态复核**:全量 pass upsert+disappearance sweep 无条件（processor :339-427）;`syncShadowTable`（:678-830）与主表同 RemoteId upsert+sweep 语义;`recomputeJunctionPairs`（:839-989）双端存在性过滤（`!mainPk || !shadowPk` continue）+ desired/existing 集合差逐对 insert/del;引擎 junction 写全 raw-knex、不经 LTARColsUpdater,守卫无 bypass 面。

## 2. updateSync link 级联五态（活体,全部通过）

| PATCH | 实测 |
|---|---|
| keep（同字段数组） | 200;镜像 RtLinks 列 id 不变;junction 配对数不变;无无谓 resync |
| `[]` | **400** `selectedFields must be a non-empty array or null (all fields)` |
| null（link 在场时） | 200;结构不动,后续全量 pass 数据正确（shadow=2 / junction=1） |
| 删 link（`["Title","Qty"]`） | 200 + 自动 full-resync;mappings 只剩 main;junction 表与 shadow 表 meta **404**（真删）;镜像 link 列移除 |
| 加回 link | 200 + full-resync;**junction 表 id 更替 = 真重建**（m24t…→mzo1…）+ backfill:源配对 → 新 junction=2 传播到位 |

## 3. 窗口 delete 收敛 + mark_deleted 两档（活体,全部通过）

- **freeze→窗口→resume catch-up**:freeze 200;窗口内改 r5 Qty=55 + 删 r4（镜像窗口期不动）;resume 200 → catch-up 走**全量 pass 含 sweep**:r5 Qty=55 落库、r4 镜像消失、junction 收敛一致、status=active 无 error。R2 E1'（catch-up 无 sweep ghost）不复现。
- **mark_deleted 档**:PATCH on_delete_action=mark_deleted → 删源 r2 → 镜像 r2 **保留** `RemoteDeleted=true`,junction 中 r2 的配对**即时清除**（orphanedMainPks 并入 flagged pks,:486-501;P4-R1 lane4b M1 修复活体成立）。
- **delete 档**:PATCH delete → 删源 r3 → 镜像 r3 行消失。
- **shadow sweep**:解链+删源 rt3 → 全量 pass 后 shadow 3→2、junction 同步收敛 ✓。

## 4. v3/v2 通道守卫（活体,全部通过;R2 E1 修复持续成立）

| 入口 | 身份 | 结果 |
|---|---|---|
| `POST/DELETE /api/v3/data/{dstBase}/{mirror}/links/{col}/{row}` | owner | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED` |
| 同两入口 | editor（dst editor） | **422** ×2（角色无关;R2 症状 200/201 不复现） |
| 拦截后 junction 配对数 | — | 不变（无部分写入） |
| editor junction 直写（v2 bulk insert） | editor | **422** prohibited |
| editor 删镜像行（v2 bulk delete） | editor | **422** prohibited |
| editor 读镜像 | editor | 200 |
| paste sync 在 Syncing 态 resync / delete | owner | **400** "Sync is already running" / deleteSync Syncing 拒——服务层守卫正向证据 |

## 5. paste 与 deleteSync（活体,全部通过）

- paste sourceSchema:无密码 → `{passwordProtected:true}`;错密码 → 400;**不列 link 列**（columns=Title,Qty）。
- paste+link createSync → **400**（硬编码英文 browse 指引,见 M-C 维持）;paste 纯标量 → 200 active,manual resync 正常。
- createSync / GET sync 响应零命中 `source_uuid` / `source_password_hash`。
- **deleteSync**（主 sync）→ 200;sync 行 404;mirror/shadow/junction 三表 meta 全 404（级联清干净）。

## 6. R3 小修验证

- **zh-Hans `labels.convertToRegularTable`（8de55d0b24）——活体闭合**:zh-Hans.json `:1432` = 「转换为普通表」,组件 SyncMenuOptions.vue 三处引用;camoufox（zh-Hans,owner 身份）树菜单实测菜单项「转换为普通表」,确认弹窗 **title「转换为普通表」+ 按钮「取消」/「转换为普通表」全中文,零英文回退**（截图 /tmp/f09p4r4l4/zh-convert-ui.png）。注:editor 身份树菜单**无** sync 段——editor 对 table-syncs list 403（R3 lane3 ACL 实测一致）,sync 管理菜单仅 owner 可见,行为正确。
- **processor/realtime 注释清理**:全仓 `watermarkStart` 零残留（dead export 已删）;processor 内 watermark/sweep 注释与实现一致,无新腐化。

## 7. 质量门

- `npx tsc --noEmit`（packages/nocodb）:**exit 0** ✓
- jest Fork 桶:**60/60,3 suites 全过**（171s;exit 0 双跑一致）✓
- Vite URL 门（formula-url-xss,`--hookTimeout 60000` 单跑）:**5/5 passed**（62.8s）✓

## M 系列（minor,全部为继承维持,无新增）

- **M-A（维持,遗留清单在案）** 源 link 列先删除时的 junction/shadow 无主僵尸（`table-syncs.service.ts:1457-1458` 通用分支兜底）;基线无 delta。
- **M-B（维持,遗留清单在案）** LTAR guard spec 覆盖缺口（removeChild/removeLinks/reorderLink/ v3 updateForColumn 零用例）;本 lane 活体双通道 422 补位,结构性缺口延续。
- **M-C（维持,遗留清单在案）** i18n 死键 `msg.warning.syncPasteLinkUnsupported` + paste+link 400 实际文案为服务端硬编码英文（本轮活体复现确认）。
- **M-D（维持,上轮本 lane 已报,orchestrator 未入修复清单,基线未变）** `table-sync.processor.ts:992-993` `cleanupJunctionOrphans` docstring 仍写「delete policy only — mark_deleted rows stay and keep their pairs」,与 :481-501（两档均清配对）注释矛盾——**纯注释失实**,行为本轮活体验证正确（§3）。

## 观察（不计 minor）

- v3 links 对象载荷只认小写 `id` 键,纯数组 `[id]` 可用（上游 APIv3 契约,R3 lane4 观察维持;本轮实测一致）。
- **UI 树 junction 条目可见性**:dst base 树显示 3 个 synced 条目（主镜像 / junction / shadow）,与 R3 报告「junction 内部表正确不显」不一致。本轮未判 error——engine 面 junction synced 语义完全正确（直写 422、deleteSync 级联清、mapping role 正确）,树条目属 UI 侧（R4 对 nc-gui 零改动,R3 结论应由 UI 专责 lane 复核定夺）。
- **测试基础设施认知**:NocoDB 同账号重复 signin 轮换 token_version 会踢掉先前 token（本轮清理段 401 复现）——后续 lane 脚本取 token 应后置或每脚本独立 signin。
- 上游 v3 `:modelId` 前一段为 baseId,真实参与解析;表 id 充当首段 → 404（R3 lane3 勘误维持）。

## 未覆盖（环境/范围限制,非「通过」）

1. AUTO 双档（scheduled interval）活体:R4 基线未触碰 trigger 代码,继承 P3 结论。
2. E1 六格 / ACL 十一端点全量、realtime 七 tap 全量复跑:基线零 delta,R3 已验;本轮仅按引擎重点路抽查守卫链（§4 全 422 面）。
3. deleteSync main 失败注错路径:P4-R1 已验,本轮仅正常路径活体（§5）。
4. editor 对 mirror 行级写入仅到 bulk-delete 422 终态,未逐层剥离 readonly 挡板顺序。

## 纪律

只读审查（`git status` packages 零改动）;未构建/未重启/未 pkill/未跑 `dev-backend*.sh`;无 psql、未提权;隔离——仅读任务书指定对照材料（r3/r2/r1 lane-prompt、r3-p4-lane3.md、r3-p4-lane4.md 本 lane 上轮报告）与仓内源码/脚本,未读本轮其他 lane 报告;测试数据全 `f09p4r4l4-` 前缀:3 账号（历史惯例保留,与历轮 lane 相同）、2 base、2 sync、全部表/行/配对——base 全删 200,名下 `f09p4r4l4*` base 残留 = **0**（清零核验）;infra 引导账号 f01e2e 仅用于建 base + 邀请 lane 账号（committed 工作脚本既定惯例）。camoufox session 已关闭,证据截图存 /tmp/f09p4r4l4/。
