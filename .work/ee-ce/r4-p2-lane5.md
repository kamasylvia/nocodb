# F09 P2 R4 修复回归 — lane 5（UI 验证重点路）报告

**结论：0 error + 1 minor** —— R3 修复批 253c3b6ee5 四项（editor 卡 gate / hash URL / 凭据剥离 / 漂移日志）活体回归全过；P1+P2 站位（向导双模式、树菜单三态+Syncing 守卫、删除流三腿）全过。唯一 minor 为 Convert 转正后当前 grid 瞬时空白（reload 即恢复，数据零丢失，非本轮修复面回归）。

基线 253c3b6ee5（R3 修复批；HEAD 2316318dad 仅 dispatch chore，`git diff 253c3b6ee5 HEAD -- packages/ src/` = 0 行）。后端 :8080 = pid 96879（2026-09-19 03:51 启动，晚于 dist mtime 03:00），dist 特征 grep：`hash.replace`×1（hash-route 解析）、`delete X.source_uuid`×2（getSync/listSyncs 双剥离）、`propagated column type change` 日志模板在位。审查时间 2026-09-19 04:0x–04:4x。

## 0. 环境与账号

- f01e2e@ 仅作基础设施（建 5 base + 邀请），lane 资源全 `f09p2r4l5-` 前缀：SRC（源表 3 列 3 行 + grid allow_sync+密码）/ SRC2（Browse 模式源，2 列 2 行，ui creator）/ D1（api owner，API 抽测）/ D2（ui owner，UI 活体 + editor 邀请）/ D3（空 base，editor 入口验证）
- 账号 f09p2r4l5-api / -ui / -e（UI/API 分离）；浏览器 signin 互踢机制复现（TU token 401 后改从浏览器 cookie `nc_token` 取活 token）
- camoufox session `f09p2r4l5` 专属，全程未动 default

## 1. R4 重点 1：editor Overview「NocoDB Sync」卡不可见（R3 lane5 E1 修复回归）—— 过

- **editor**（f09p2r4l5-e）开空 base D3：`document.body.innerText` 断言 `hasSync:false`（SYNC-CARD-ABSENT），同屏 Create New Table / Import Data 卡亦不可见（editor 无 tableCreate，role 管线正常反证）——截图 `editor-d3-home-r4.png`
- **creator**（f09p2r4l5-ui）开 D2：`hasSyncCard:true` + Create Table/Import 全可见（gate 无误伤）——截图 `creator-d2-home-r4.png`
- 源码复核 `Overview.vue:134-140`：卡 v-if = `!isMobileMode && !blockTableSync && isUIAllowed('sourceCreate')`，与相邻 Connect External Data 卡（:144）同源 gate，注释带 `[CE-EE] F09 P2-R3(lane5)` 标记

## 2. R4 重点 2：hash 形共享 URL 三入口（R3 lane4 M-1 修复回归）—— 过

D1（api owner，无源权限——paste 凭据语义背书）：

| 入口 | hash URL `…/#/nc/grid/<uuid>` | 对照 |
|---|---|---|
| resolve-link | **200** 全量坐标（base/table/view 命中 SRC） | path URL 200 / 裸 uuid 200（回归不破） |
| source-schema | **200** 全 schema（3 列预览） | — |
| createSync | **200** → 引擎拉数 **3 行全进**（row1/2/3） | — |
| protected 无密码 | 仅 `{passwordProtected:true}`（R1 M1 零泄露回归） | — |

注：resolve-link body 字段名为 `sharedViewUrl`（首测误用 `url` 得 400 系测试脚本字段名错误，非产品缺陷——path URL/裸 uuid 同 400 佐证，改字段名后三形态全 200）。

## 3. R4 重点 3：响应凭据剥离（R3 lane2 修复回归）—— 过

- getSync 映射行 keys：`base_id,created_at,dest_*,fk_*,id,role,source_base_id,source_table_id,source_view_id,source_workspace_id,updated_at` —— **无 source_uuid / source_password_hash**
- getSync + listSyncs 响应 grep `source_uuid|source_password_hash`：**0 命中**（D1 与 D2 双 base 验）
- 明文凭据不落库回归：paste sync 建后引擎拉数正常（持久凭证通道工作）

## 4. R4 重点 4：漂移日志「旧值 -> 新值」（R3 lane4 M-2 修复回归）—— 过

- 源 Qty Number→SingleLineText（PATCH 200）+ 源行改 "txt-42" → resync 200 → 镜像列 uidt=SingleLineText readonly=true + row1 Qty="txt-42" 真实流过
- 后端日志（/private/tmp/nocodb-internal.log）活体捕获：
  `Table sync tss5l6s4ua6vvy1co: propagated column type change Qty: bigint -> SingleLineText`
  —— **旧值（pre-change dt=bigint）-> 新值** 格式正确（修复前为 new→new）

## 5. UI 活体：向导双模式全流程 —— 过

- **Browse 模式**（P1 回归，D2 + SRC2）：step0 Browse 默认选中 → base 选择器（仅列 ui 有权 base，SRC/D1/D3 无权限不列 ✓）→ 表选择 → **schema.view=null 时 Next disabled + allow_sync 提示**（设计行为：SRC2 未开 allow_sync 时 Next 恒禁，开 allow_sync 后解禁——P1 allow_sync 前置语义在位）→ step1 切 specific fields 勾 Name → step2 表名+Retained 策略 → Create sync → 树镜像表 + API `synced=true` + **镜像仅 Name 列、数据 b1/b2 进、Price 不在**（selected_fields UI 路径真实生效）
- **Paste 模式**（P2 回归，D2 + SRC path URL）：切 Paste link → URL 填入后**密码框随现**（v-if sharedViewUrl ✓）+ Next 解禁 → resolve → 字段步（All）→ Create sync → 树镜像 + API `mode=paste status=active` + 3 行数据（Qty="txt-42" 漂移后值一致）
- listSyncs：`browse`/`paste` 双 sync 并存 mode 标注正确

## 6. UI 活体：树菜单三态 + Syncing 守卫 —— 过（R1 M3 修复回归实证）

- **Active 态**（`menu-active-r4.png`）：Synced table 徽标 + Sync now / Pause sync / Convert to regular table / Delete sync 四项全在
- **Paused 态**（`menu-paused-r4.png`）：Pause sync → 重开菜单即翻转 **Resume sync**（无需 reload，R5 open-watch 在位）
- **Syncing 态**（`menu-syncing-guard-r4.png`）：Resume → Sync now → **立即重开菜单**竞态命中——菜单收敛为常规组 + 「Syncing」状态行，**Sync 组四项全部消失**（R1 M3 `v-if status !== Syncing` ×4 活体回归 ✓）；job 完成（API active）后重开菜单恢复全项
- 附带：镜像表 grid New record disabled（synced 只读守卫）

## 7. UI 活体：删除流三腿 —— 过

- **腿 A｜Delete sync**（`delete-sync-confirm-r4.png` + `after-delete-sync-r4.png`）：确认弹窗（Cancel/红色 Delete sync）→ confirm → 树中 browse_mirror 消失 + **URL 自动跳转剩余表 paste_mirror**（R6/R8 redirect 链活体回归）；API sync 列表剩 1、表进 trash
- **腿 B｜Convert to regular table**：paste_mirror → Convert → API sync 列表 0、`synced=false`、表留树；转正表 **API 插行 200**（Id=4，readonly 守卫解除）；reload 后 grid 4 行无锁标 + **New record 恢复可用**（`after-convert-reload-r4.png`）
- **腿 C｜菜单翻转**（`converted-menu-r4.png`）：转正后菜单 **Delete table 出现、Sync 组三项（Sync now/Convert/Delete sync）全消失**

## 8. Minor（1）

| # | 级别 | 现象 | 判定依据 |
|---|---|---|---|
| M-1 | minor | **Convert 转正后当前 grid 瞬时空白**：点击 Convert 后当前视图列头/行消失（`after-convert-r4.png`），手动 reload 后完全恢复（数据 4 行、权限、菜单状态全对） | 数据零丢失（API 全程可读、插行 200）、状态层无损、reload 即恢复；R3 lane5 同流程未复现（时序敏感瞬态）；非本轮修复面（253c3b6ee5 未触碰 detach 前端路径）——低危 UX 瞬态，建议 P3 轮顺带看 removeMeta→视图重建时序 |

## 9. editor 三入口 R3 PASS 项未重打说明

入口 2（树 synced 表菜单）与入口 3（Share allow_sync 开关）本轮未重打：253c3b6ee5 与 HEAD 均未触碰 SyncMenuOptions.vue / SharePage.vue / View.vue（diff 仅 Overview.vue + 后端 2 文件），R3 两项 PASS 无回归面；入口 1（Overview 卡）已活体重验为本次修复核心。D2 测后段 sync 全清无 synced 表可复用，亦无重建必要。

## 10. 质量门 —— 全绿

| 门 | 结果 |
|---|---|
| `tsc --noEmit` | exit 0 |
| jest Fork 桶 | 3 suites / **41 tests 全过** |
| Vite URL 编译强验 | CreateNewSync.vue 200 / SyncMenuOptions.vue 200 / **Overview.vue 200**（本轮修复文件加验），均含 createHotContext 真实编译产物 |

## 11. 纪律与清理

- 只读审查零源码改动；未构建/重启/跑 dev-backend*.sh/pkill/psql super；未读他路报告（仅任务书链 r4-p2-lane-prompt → r3-p2-lane-prompt + r3-p2-lane5）
- 清理：5 个测试 base（SRC/SRC2/D1/D2/D3 全 `f09p2r4l5-` 前缀）经 f01e2e DELETE 全 200，base 列表残留 0；lane 账号 3 个留存（基建惯例，口令不入仓）；camoufox session f09p2r4l5 已 close

## 证据索引

- 截图：/tmp/f09p2r4l5/shots/（editor-d3-home-r4 / creator-d2-home-r4 / wizard-step0-browse / wizard-browse-step0 / wizard-browse-step1-fields / wizard-browse-step2 / after-browse-create / wizard-paste-step0-r4 / after-paste-create-r4 / menu-active-r4 / menu-paused-r4 / menu-syncing-guard-r4 / delete-sync-confirm-r4 / after-delete-sync-r4 / after-convert-r4 / after-convert-reload-r4 / converted-menu-r4）
- 脚本：/tmp/f09p2r4l5/（setup.sh、t1.sh、env.sh）
- 后端日志：/private/tmp/nocodb-internal.log（漂移日志行 04:00:18）
- 质量门日志：/tmp/f09p2r4l5/tsc.log、/tmp/f09p2r4l5/jest.log
