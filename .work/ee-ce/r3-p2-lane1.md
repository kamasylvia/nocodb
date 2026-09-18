# F09 P2 生命周期 R3 站位回归 — lane 1 报告

**结论：PASS（0 error + 0 minor）**

- 审查基线：366e0b7045（R1 修复批）；`git diff 366e0b7045 HEAD -- packages/ src/` = 0 行（基线后零代码变更）
- 后端 :8080 pid 33253 运行修复后 dist（P2 特征 grep：sourceInputMode/resolveLink/source_password_hash/sharedViewPassword/detach/bypassSyncedFieldGuard 全命中）
- 前端 :3000 HMR；camoufox session `f09p2r3l1`；账号前缀 `f09p2r3l1-*`（UI/API 分离，超管仅 bootstrap invite）

## 一、质量门

| 门 | 结果 |
|---|---|
| tsc --noEmit | exit 0 |
| jest Fork 桶 | 3 suites / **41/41 pass** |
| Vite URL 编译门 | CreateNewSync.vue → 200；SyncMenuOptions.vue → 200 |

## 二、P2 六项站位回归（API 实测）

1. **paste 模式全链**（跨账号凭据语义）：paste 账号（无源 base 权限，读源 403 背书）持共享 URL+密码 → resolve-link 三分支：无密码仅 `{passwordProtected:true}`（零 title 泄露）/ 错密码 400 / 对密码返回全量坐标+`sourceInputMode:paste`；sourceSchema paste 分支双形态同验。createSync 不带 sourceTableId → 200 建镜像 + 引擎拉 3 行；mapping 落 `source_uuid` + `source_password_hash`（bcrypt 60 字符，无明文字段）；paste resync 凭持久凭证 200（不查 base 权限）+ 源增行后数据流过（4 行）；allow_sync 关 → paste resync 400。
2. **selected_fields 增删传播**：减态起步（Title,Price）镜像两列；**+Qty → 200 → 新列 readonly=true → resync 后 Qty 真实进数（1/2/3）**（R1 E4 回归核心）；减列回 [Title] → 200 无 500 → Price/Qty 列删+映射删+resync 对齐（R1 E2/E3 回归）；边界：[]→400、未知 title→400、null→200 恢复全字段+数据进数。
3. **源列类型漂移**：源 Qty Number→SingleLineText（200）+ 源行值 5→"txt-99" → resync 后镜像列 uidt=SingleLineText 且 readonly 保持 true（bypassSyncedFieldGuard 权威通道）+ 行值 "txt-99" 真实流过。
4. **detach 转正**：POST detach 200 → synced=false、readonly 列 0、映射/sync 删、表与行保留；detach 后写入 200（可编辑）；Syncing 中 detach 400（见 §4 窗口守卫）。
5. **resync 复检**：allow_sync 关 → resync 400；重开 → 200；browse 模式源权限断言在源码 assertSourceReadAccess（R5 平台谓词镜像）。
6. **原子性**：代码审——createSync 中 tableCreate 之后全部步骤（GVC 隐藏/system 补丁/插入 sync/mapping/列映射/入队）包在 try/catch，catch 中 `tableDelete(forceDeleteSyncs:true)` best-effort 回滚 + rethrow（table-syncs.service.ts:605-734）；黑盒无法稳定注入中途故障，接受代码审口径（R1/R2 同）。

## 三、P1 全矩阵回归

- **ACL**：owner 十端点全 200（list/get/schema/create/update/resync/freeze/resume/delete + resolve-link 400 语义正确 + **detach** 200）；editor/viewer **十+1 端点（含 detach）全 403**；匿名 401。
- **引擎 e2e**：full-create（4 行）；delete 策略源删行→镜像 4→3；mark_deleted 策略源删行→**行保留 + RemoteDeleted=true 置位**（records API 可见位、网格列不可见为 P1 既裁）；分页读源 2000 行（4×500）正常完成镜像 2000 行；freeze→resync 400→resume→200。
- **守卫链**：editor 对 synced 镜像 insert → 400；RemoteId/RemoteDeleted 系统列 system+show 双隐藏（P1 既裁不重开）。
- **付费锁**：createSync `syncTrigger=realtime` → 400「Only the manual sync trigger is supported」。
- **F 探针**：F02/F03 permissions list、F04 ext syncs list、F05 variables、F07 snapshots、F08 base read、F10 dashboards 全 200；Airtable sync 通道（`POST .../syncs {type:Airtable}`）200 不回归。

## 四、UI 活体（camoufox session f09p2r3l1，UI 账号）

1. **向导 paste 流**：入口「NocoDB Sync」→ Browse/Paste link 单选（P2 step0）→ 贴 URL 后密码框出现 + Next 解禁（resolve 已过）→ 填密码 → 字段步（All/Select specific）→ 表名+双删除策略步 → Create sync → API 侧 sync active + `source_input_mode=paste` + 镜像 3 行。
2. **树菜单三态**：active 态 = Sync now / Pause sync / **Convert to regular table** / Delete sync 四项齐；paused 态 = Pause sync 变 **Resume sync**（API paused↔active 翻转核对）；**Syncing 态（2000 行 resync 窗口内）= sync 四项全部不可见**（M3 守卫活体）；detached 态 = 无任何 sync 项（仅通用项+Delete table）。
3. **删除流三腿**：Delete sync → 确认弹窗 → sync=0 + 镜像表进 trash；Convert to regular table → synced=false + readonly 全解 + sync 消失表保留；Pause/Resume 双态见上。
4. 截图 7 张：`.work/ee-ce/r3-p2-lane1-shots/01..07`（01 paste resolve、02 向导末步、03 active 菜单、04 convert 项、05 detach 后菜单、06 delete 确认弹窗、07 syncing 守卫菜单）。

## 五、观察项（非 error/minor）

- **dev 前端瞬时 Network Error**：UI 段会话内 4 次弹回登录（Nuxt dev 代理层瞬时失败；:8080/:3000/进程全程存活、同期 API 均成功、重登即恢复）。生产构建无该代理层，判环境抖动不判产品缺陷；一次 Resume 点击因此落空（重试生效）。
- detach 无确认弹窗（与 P2 实现自述一致，两轮既过不翻案）。
- 脚本踩坑备查：v2 records 删行 body 须 `[{"Id":N}]`（裸数组 400）；行级 PATCH `/records/:rowId` 该版本不存在（bulk PATCH `{"Id":..}` 可用）；zsh `status`/`UID` 只读、数组 1-indexed。

## 六、纪律与清理

- 只读审查零源码改动；未构建/重启/跑 dev-backend*.sh/psql；未读他路 R2/R3 报告（仅任务书链允许的 r1-p2-lane1/5）。
- 清理复核：`f09p2r3l1-*` base 残留 0；测试账号 7 个全删（api/-p/-e/-v/-ui + 2 个早期 signup 残留）复核 0；Airtable 探针 sync 随 base 级联清除；`f09_src_*` 2 个为 P1 selftest 历史残留非本 lane 前缀未动。
- 报告落盘：`.work/ee-ce/r3-p2-lane1.md`；截图 `.work/ee-ce/r3-p2-lane1-shots/`。
