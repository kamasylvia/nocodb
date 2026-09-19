# F09 P3 R4 站位回归 — lane1 报告（2026-09-19）

## 结论

**PASS — 0 error + 1 minor**

审查基线 = 8de55d0b24（R3 后零代码功能变更，复核确认：`git diff 5d25acfc51..8de55d0b24` 仅 zh-Hans.json +1 键、table-sync-realtime.ts 注释 6 行、.work 流程文件）。后端 :8080 运行正常（health 200 全程）。

## 质量门（全过）

- `npx tsc --noEmit` = 0 error
- `npx jest --testPathPattern 'Fork'` = 44/44（3 suites）
- Vite URL 编译门：CreateNewSync.vue / SyncMenuOptions.vue 均 200

## R4 增量①：zh-Hans Convert 确认弹窗（活体实锤）

camoufox session `f09p3r4l1`，中文界面（localStorage `nocodb-gui-v2.lang=zh-Hans`）：

- 树菜单五项全中文：同步表 / 立即同步 / 暂停同步 / **转换为普通表** / 删除同步
- Convert 弹窗：标题「转换为普通表」、body `ui_auto_t — "ui_auto_t"`、按钮「取 消」+「转换为普通表」——**零英文回退**（截图 `/tmp/f09p3r4l1-convert-dlg.png`）
- Cancel 路径：弹窗关、sync 仍在（in-browser fetch 计数 =1）
- 确认路径：sync 移除（=0）、镜像 `synced=false`、行写入 200、树节点图标回普通表、无瞬空白帧（R3 修复 holds，截图 `/tmp/f09p3r4l1-after-detach.png`）

## R4 增量②：站位全回归（R3 同规格）

### 活体① run1（`.work/ee-ce/f09p3r4l1-run1.sh`，22 PASS / 0 FAIL）

- **realtime 全链**：单插（亚秒）/ 单改 / 单删（ghost 收敛）/ 数组体 bulk 插 3 行 / bulk 删 2 行——五腿全传播
- **幂等复跑**：resync 后行数不变
- **AUTO 双档**：manual sync（第二表）源写 8s 不自播；Sync now 追平 3 行；realtime sync 自动传播
- **paused 窗口**：freeze → 三写（插 paused_new / 改 bulk_c / 删 ins_single）→ 镜像冻结 4 不动 → resume → catch-up **三腿全追平**（R2 ghost 场景零复现）
- **Syncing 窗口**：600 行大源 resync 中三写（插 win_new / 改 big_1 / 删 big_2）→ run + catch-up 收敛（win_new 在 / win_upd 在 / big_2 无）→ 终态 src=604 = mirror=604

### 活体② run2（`f09p3r4l1-run2.sh`，全 PASS）

- paste 全链：share uuid+密码 → source-schema（对密码 400 / 正密码 200）→ createSync(paste+realtime+selectedFields=[Name]) → 镜像只建 Name 列 + 3 行
- 凭据剥离：getSync 无 source_uuid / source_password_hash
- selected_fields 传播：camelCase `selectedFields` PATCH 生效（Qty 列加回+数据传播）；snake_case 删列生效（Qty 列消失）；收窄后 realtime 增量仍走
- 类型漂移：源 Qty Number→SingleLineText → resync → 镜像列 uidt 跟随（旧值在前 Number → SingleLineText）
- resync 复检：allow_sync 关 → 400 / 开 → 200
- mark_deleted 腿：删源行 → 镜像行留 RemoteDeleted=true、行数不变
- detach：synced=false + 可写 200 + 行保留

### 活体③ ACL 六格 + realtime 同权 + 守卫链（run3/3b/3c + 定点实验，终版 6/6）

前置发现（测试设计层，非产品缺陷）：①createSync @Acl 是 creator+，源读谓词必须以 dest=creator 账号探（editor 403 先拦，与 R2-R3 lane5 卡 gate 语义一致）；②base 用户角色枚举是**连字符** `no-access`，invite/PATCH 传 `no_access`（下划线）被 400 校验拒——前两轮六格的 no_access 格 200 全系枚举误用伪影。终版结果：

| 格 | 象限 | 结果 |
|---|---|---|
| 1 | 非私有 + 显式 editor | 200 ✓ |
| 2 | 非私有 + 显式 no-access | 404 ERR_BASE_NOT_FOUND ✓（dd46a3eb1d 短路活体） |
| 3 | 非私有 + 无 base 行 | 404 ERR_BASE_NOT_FOUND ✓ |
| 4 | 私有 + 显式 editor | 200 ✓ |
| 5 | 私有 + 显式 no-access | 404 ERR_BASE_NOT_FOUND ✓ |
| 6 | 私有 + 无 base 行 | 404 ERR_BASE_NOT_FOUND ✓ |

- realtime sync 同权：editor 对 realtime 建的 sync resync/freeze/resume/detach/DELETE/PATCH 全 403；listSyncs 403（creator+ fail-closed，P1 口径）
- 守卫链：镜像行插/改 400（readonly 列守卫 fail-closed）、删 422（ERR_SYNC_TABLE_OPERATION_PROHIBITED）、editor 删镜像表 403；守卫未误伤引擎写（rt_guard 行照常传播）
- deleteSync 流（一次性验证）：DELETE 200 → GET 404 → list 空 → 镜像表入 trash（meta 404）

### UI 活体（camoufox，中文界面）

- 向导：浏览/粘贴链接双模式 + AUTO 双档（自动使用/手动操作）单选均可用；UI 建 realtime sync 落库 `sync_trigger=realtime`（API 复核）；UI 建手动档第二 sync 成功
- 树实时刷新：创建后节点 pre=0 → post=1 无重载（R6 修复 holds）
- 树菜单三态：同步表 → 暂停后「已暂停」+ 恢复同步项出现 → 恢复后回「同步表」（正在同步为瞬态，本轮未定格，标签逻辑同源）
- 删除流三腿：删除确认弹窗（删除同步 标题/body/取消/确认）→ 确认后镜像入 trash、sync 移除、**自动跳转 remaining[0]=ui_auto_t**（R6 oldActiveTableId 腿活体）；detach 后普通表菜单无 sync 项（守卫正确）
- detach 后树菜单回退普通表菜单验证（无幽灵 sync 项）

## Minor（1）

**M1 · table-sync.processor.ts 头注释自相矛盾（注释腐烂，行为已实测正确）**
`packages/nocodb/src/modules/jobs/jobs/table-sync/table-sync.processor.ts:28-32` 及 `:53-55`：注释写 "an incremental run with no ids … falls back to the full pass (upsert + sweep) **and skips the disappearance sweep**" / "or the full-pass catch-up (catch-up), **skipping the disappearance sweep**"。实际代码（`:320-409` else 分支）无 ids catch-up = **全量 pass 含消失 sweep**（R2 E1' 修复本体），且活体①8c 窗口删腿经 sweep 收敛实测。前半句 "with no ids without touched ids" 亦语句混乱。R4 基线 commit（8de55d0b24）主题为「comment rot cleanup」，此两处漏网。仅注释，无需阻塞；建议下轮顺手清理。

## 覆盖缺口（如实记录，不判 error）

- 「Syncing 中 updateSync/deleteSync/detach → 400」三条生命周期守卫本轮未重测（P1/P2 已验，本轮零功能变更）；本轮覆盖了 resync-during-Syncing 的等价守卫（Syncing 窗口 CAS miss 路径活体）。
- 树菜单「正在同步」瞬态标签未定格观察（标签 computed 同源，暂停/活动两态已活体）。

## 过程自伤记录（均已纠正，非产品问题）

1. run1 首跑 v2 写端点误用（PATCH/DELETE 不带 Id 平铺 body → 404 静默）→ 修正后全绿。
2. 六格两轮伪影（dest ACL 前拦 / no-access 连字符枚举）→ 终版 6/6。
3. 用 curl 登 UI 账号复核 sync 触发 token_version 互踢、踢掉浏览器会话（Network Error 弹登录页）——UI/API 账号分离纪律自伤；改用浏览器内 fetch 复核，重登后流程走完。

## 清理

- base 残留 0（9 个 f09p3r4l1* base 全删，含前两轮失败跑遗留）
- 测试账号 3 个全删（f09p3r4l1-api / -editor / -ui，admin API 200 ×3）
- 残留复查 0 / 0；:8080 health 200
- camoufox session f09p3r4l1 已 close
- 过程脚本存档：`.work/ee-ce/f09p3r4l1-run{1,2,3,3b,3c}.sh`（未跟踪 .work，不入 git）
