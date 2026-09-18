# r3-p2-lane4 — F09 P2 R3 站位回归（引擎重点路）

## 0 error + 2 minor —— R2 保持全绿，连击 3/3 条件满足（本路）

基线：代码 366e0b7045（R2 后零代码变更，HEAD 7db46fce29 仅 dispatch）；后端 :8080 pid 33253（health 200 全程）；前端 :3000。审查账号 f09p2r3l4-api@test.local（API）/ f09p2r3l4-ui@test.local（UI），两号均受邀为 src/dst base creator。共享账号 f01e2e@ce-ee.local 仅用于一次性提权与 base 删除（见 §5 运维注记）。

## 结论头

**0 error + 2 minor**。R1 五 error 修复项逐一活体回归无复发；P1 全矩阵抽检 pass；引擎四重点（paste 拉数 / selected_fields 增列真实进数 / 类型漂移双向传播 / RemoteId 键控 upsert+双删除策略）全部活体验证通过。

## 1. R1 修复回归（逐项活体）

| R1 error | 本轮验证 | 结果 |
|---|---|---|
| E1+E2 paste createSync 上下文错位 | `POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>, sharedViewPassword}`（无 sourceTableId）→ 200，镜像 4 行真实进数，mapping 落 `source_uuid` + `source_password_hash`（bcrypt hash，明文未落库） | pass，不复发 |
| E3 selected_fields 减列 undefined binding | PATCH 减 Qty → 200，镜像列删 + 映射删 + 数据对齐 | pass，不复发 |
| E4 增列 dest_column_id 落 model id | 源加 Price 列 + 填值 → PATCH 增列 → 镜像新列（readonly=true）→ resync 后 **Price 11/22/44 真实进数** | pass，不复发（核心回归点） |
| resolveLink 密码泄露 | 无密码 → 仅 `{passwordProtected:true}`，无 title/坐标泄露；错密码 → 400 `Invalid shared view password`；对密码 → 全量坐标 | pass，不复发 |
| M3 树菜单 Syncing 守卫 | 活体抓拍 Syncing 态菜单：Sync now/Pause/Convert/Delete 全部隐藏（见 §3） | pass，不复发 |

## 2. 引擎四重点（lane 4 主责，活体）

1. **paste 全链**：resolveLink（URL/裸 uuid 双形态）→ sourceSchema paste 分支（无密码 `{passwordProtected:true}` / 对密码 columns 全量）→ createSync → 引擎 full-copy 4 行（Title/Qty 正确，RemoteId=1..4，RemoteDeleted=false，映射列 readonly=true，RemoteId/RemoteDeleted system=true 隐藏）→ status active、last_synced_at 落。UI sync3（向导建）resync 后 605/605 行进镜像（分页 SYNC_PAGE_SIZE=500 跨页正确）。
2. **selected_fields 传播**：增列（Price）真实进数如上；减列（Qty）列删+映射删；`[]`→400 `selectedFields must be a non-empty array or null`；未知字段→400；`null`→全字段（Qty 列重建回镜像）。
3. **源列类型漂移双向传播**：源 Qty Number→SingleLineText，resync → 镜像 uidt/dt 跟随（Number/bigint→SingleLineText/text），**readonly=true 保留**（processor 漂移腿未 re-assert readonly，实测 columnUpdate 只动 uidt/dt 不丢标志）；数据仍进（值变字符串）。源改回 Number → 镜像回 Number/bigint，数据回数字。sync status active、last_error null。守卫链源码确认：columns.service `_runColumnUpdate` `bypassSyncedFieldGuard` 置 isSyncedColumn=false 跳过 synced 守卫（columns.service.ts:980-984），走完整 ALTER 通道。
4. **RemoteId 键控 upsert + 双删除策略**：
   - update：源 row2 Qty 1→99 → resync → 镜像 99（Id 键控 update）
   - insert：源 row5 新增 → 镜像新进
   - **delete 腿**（onDeleteAction=delete）：删源 row3 → 镜像真删（4 行）
   - **mark_deleted 腿**（sync2 独立 mark_deleted）：删源 row5 → 镜像行保留 + RemoteDeleted=true，且源行恢复时 payload 置 false 的通道在源码（processor.ts:247-253）
   - 两个 sync 同源独立驱动各自 dest，互不串扰。

## 3. detach / 守卫链 / P1 抽检（活体）

- **detach 转正**（sync2）：`POST .../detach` → 200；synced True→False；sync 行消失（get 404）；全列 readonly 解除；表保留且 PATCH 写数 200（detached-edit）。SyncMenuOptions onDetach 流（removeMeta+loadTables）源码在。
- **freeze/resume + Paused 守卫**：freeze→paused；Paused 态 resync/update/freeze 二连各 400（报错文案精确）；resume→active。
- **synced 列用户写守卫**：PATCH 镜像 Title → 400 `Column "Title" is readonly column and cannot be updated`（allowSystemColumn 白名单未泄 HTTP 层）。
- **deleteSync**：DELETE → 镜像出 base 表列表（trash 语义）、sync 404。
- **createSync 原子性**：难活体构造（失败点需在 tableCreate 后）；代码审确认 try 包住 getColumns→GVC patch→system patch→insert→mappings→enqueue，catch 内 best-effort `tableDelete(forceDeleteSyncs)` + rethrow（table-syncs.service.ts:605-734）。
- **Syncing 中 update/delete/detach/resync 400**：service 源码四处守卫在（:812/:1006/:1037/:1178）；活体窗口用 §3 UI 抓拍佐证前端同款守卫。

## 4. UI 活体（camoufox session f09p2r3l4，截图 .work/ee-ce/f09p2r3l4-shots/）

1. **向导 paste 流**：Create New → NocoDB Sync → Browse/Paste 单选（默认 Browse，Paste 选中后 URL 框 + optional 密码框出现）→ 粘 URL+密码 → Next resolve 通过 → 字段步（All fields/Select specific fields）→ 表名+删除策略步 → Create sync → 树出现镜像表，Syncing→idle（wizard-paste-fields.png / wizard-created-syncing.png）。
2. **树菜单三态**：
   - 普通表（转正表 mirror-md）：Rename/Icon/Duplicate/Description/Permissions/Delete，**无任何 Sync 项、无 Convert**；
   - synced idle：Sync now / Pause sync / **Convert to regular table** / Delete sync + 状态行 "Synced table Last synced …"；
   - **Syncing 态**（600 行源 + Sync now 后 ~1.4s 抢拍）：sync 专属四项全隐藏，仅剩通用表操作（syncing-state-menu.png）。
3. **删除流**：菜单 Delete sync → 确认弹窗 → 树刷新镜像消失、table-syncs 列表清零。

## 5. minor（2 项，均不阻塞）

- **M-1** `extractSharedViewUuid`（table-syncs.service.ts:98-111）不识别 hash 形态共享 URL（`…/#/nc/grid/<uuid>` → 400 "A valid shared view URL or uuid is required"）。`new URL()` 成功后只取 pathname，fragment 里的 uuid 丢；且 try 成功不走 fallback。前端 SharePage 生成的共享链接是 path 形态（`dashboardUrl + /nc/grid/<uuid>`），复制回贴全链可用（活体验证）；仅用户手贴旧 hash 形态链接受影响。建议：解析失败时对 hash 段再取末段。
- **M-2** processor 漂移日志时机错位（table-sync.processor.ts:169-173）：先 `destCol.uidt = srcCol.uidt` 再 log `${destCol.uidt} -> ${srcCol.uidt}`，实际输出恒为 "新值 -> 新值"，丢失变更前类型，排障价值为零。纯日志失真，功能零影响。
- 观察项（不判 violation）：漂移 columnUpdate 后 destBaseModel 实例 meta 未重建，本轮 typecast 写入依赖 PG 隐式 cast——实测双向漂移数据均正确进出；且下轮 resync 重建 model 自愈。paste 凭证引擎拉全表（ignoreViewFilterAndSort）而非共享视图子集——共享视图=授权边界的设计决策，R1/R2 已两轮接受，本轮不重开。

## 6. 质量门

| 门 | 结果 |
|---|---|
| `tsc --noEmit`（packages/nocodb） | exit 0 |
| jest Fork 桶（testRegex Integration/Source/Fork） | 3 suites 41/41 pass |
| Vite URL（:3000 `/_nuxt/<path>` 200=编译过） | CreateNewSync.vue 200 / SyncMenuOptions.vue 200 / useTableSync.ts 200 |

## 7. 运维注记（非审查项）

- **共享账号互踢**：`f01e2e@ce-ee.local` 每次 signin rotate token_version，多路并发复用会互相使 token 失效（本轮 resolve-link 连环 401 根因）。已改用专属账号（f01e2e 仅一次性提权/删 base）。后续 lane 若复用共享账号建议同样「邀请自号进 base 后全程自号」。
- UI 账号邀请：base 级 `POST /api/v2/meta/bases/:id/users {email,roles:'creator'}`。
- v2 records 单行更新/删除无 `/records/:rowId` PATCH/DELETE，需批量形态（数组 body）。

## 8. 测试数据清理

- base ×2（f09p2r3l4-base-src / f09p2r3l4-base-dst，含全部镜像表/sync/行数据）已删（base 列表核查 0 残留）。
- 账号 f09p2r3l4-api/ui@test.local 保留（无 base 归属，不占资源；账号无自删端点，如需清除走 admin）。
- camoufox session f09p2r3l4 已 close。源码零改动（全程只读）。
