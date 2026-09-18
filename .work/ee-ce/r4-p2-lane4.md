# F09 P2 R4 — lane 4（引擎重点路）报告

**结论：PASS — 0 error + 1 minor**。R3 四项修复回归（hash 形共享 URL 全链 / 响应凭据剥离 / 漂移日志「旧值 -> 新值」/ editor Overview 卡 gate）全部活体或代码+编译双验通过；R4 重点四项（hash URL 链、selected_fields 增列真实进数、源列类型漂移传播、RemoteId 双删除策略）全过；P1+P2 站位（browse 链、resync 复检双腿、detach 转正、守卫链、editor ACL、deleteSync）无复现。唯一 minor 为顺带发现的 share 端点密码设置观察项（非本轮修复面，详见 §7）。

基线 253c3b6ee5（R3 修复批，HEAD=2316318dad 仅 dispatch chore）。审查时间 2026-09-19 凌晨。后端 :8080 = pid 96879（03:51 起）> dist mtime 03:00，dist 含 R3 修复特征（"legacy hash-route form" / "strip the share credential" grep 命中），全程未构建未重启。

## 0. 环境与账号

- f01e2e@ 仅基建（建 4 base + editor 邀请）；lane 资源全 `f09p2r4l4-` 前缀：SRC base（f09p2r4l4_src_tbl：Title/Note/Qty(Number) × 3 行 + 默认 grid view allow_sync+密码）/ D1（paste 链主战场）/ D2（browse 链 + mark_deleted + editor 邀请）/ D3（备用）
- 账号 f09p2r4l4-api（creator，API）/ f09p2r4l4-e（editor，D2 内）；UI/API 天然分离（本路无 UI 登录）。实测提醒：f01e2e token 会被并行 lane 互踢（token_version 轮换），跨步操作须逐步重签
- camoufox session `f09p2r4l4` 未动用（引擎路全程 API+日志可达）；后端日志 = /private/tmp/nocodb-internal.log（pid 96879 stdout）

## 1. R4 重点①：hash 形共享 URL 全链 —— 过

R3 lane4 M-1 症状（hash 形 400 "A valid shared view URL or uuid is required"）**不复现**。extractSharedViewUuid 修复（pathname+hash 双候选、reverse 从尾找 uuid）实测：

| 断言 | 结果 |
|---|---|
| resolveLink `…/#/nc/grid/<uuid>` 无密码 → 200 坐标（修复前 400） | PASS |
| resolveLink `…/#/nc/view/<uuid>`（另一 hash 形态）+ 对密码 → 200 全坐标 passwordProtected:false | PASS |
| sourceSchema hash 形 + 密码 → 200（paste 分支，cols=[Title,Note,Qty]） | PASS |
| createSync paste hash 形 URL（selectedFields=[Title,Note]，delete 策略，不带 sourceTableId）→ 200 建镜像 + job 完成 active | PASS |
| 错 URL（无 uuid 段）→ 400 valid URL required | PASS |

## 2. R4 重点②：selected_fields 增列真实进数 —— 过

R1 E4（dest_column_id 落错 id 臂数据永不同步）修复回归，实测真实进数：

- PATCH selected_fields [Title,Note]→[Title,Note,Qty] → 200；镜像 Qty 列出现（readonly:true，v1 meta 实测）；resync 200 → **镜像 Qty = 1/2/3 真实数据**（API records 实读，非 null）
- 减列 [Title,Note,Qty]→[Title,Qty] → 200，Note 列消失（列+映射同删）
- selected_fields null → 200（全字段语义）；`[]` → 400 拒绝

## 3. R4 重点③：源列类型漂移传播 + 日志「旧值 -> 新值」 —— 过

R3 lane4 M-2（日志打印 new→new）修复回归：

- 源 Qty 列 PATCH Number → SingleLineText（dt: bigint → text）→ resync → **镜像 Qty uidt=SingleLineText / dt=text**（bypassSyncedFieldGuard 引擎通道生效）
- 后端日志实锤（/private/tmp/nocodb-internal.log 增量段）：
  `Table sync <id>: propagated column type change Qty: bigint -> SingleLineText`
  **旧值（变更前 destCol.dt）在前、新值在后，两侧不同** —— M-2 症状（new→new）不复现；同轮日志 `source rows=3 existing=3 inserts=0 updates=3`（漂移后数据正常重写）

## 4. R4 重点④：RemoteId 双删除策略 —— 过

| 腿 | 操作 | 实测 |
|---|---|---|
| delete 策略（D1） | 源删 row3 → resync | 镜像 3→2 行，RemoteId 仅剩 [1,2]（bulkDelete 物理删路径） |
| mark_deleted 策略（D2） | browse 建同步 → 源删 row1 → resync | 镜像行数不变，row1 保留且 **RemoteDeleted=true**（标记路径） |
| 行重现清 flag | 源码审（processor L250-257） | matched 分支在 markDeleted 时强制 `RemoteDeleted=false`，逻辑在位（需同 pk 重现，PG serial 无法活体构造，P1 已验本轮不重开） |

## 5. R3 修复其余项回归（本路交叉验证）

- **响应凭据剥离（R3 lane2）**：getSync/listSyncs 响应 mappings 均 **ABSENT** source_uuid/source_password_hash（实测两 sync × 两端点）；明文不落库（bcrypt hash 服务端持有）
- **editor Overview 卡 gate（R3 lane5 E1）**：代码审 Overview.vue `v-if="!isMobileMode && !blockTableSync && isUIAllowed('sourceCreate')"`（253c3b6ee5）在位；ACL 表 editor 段无 sourceCreate → creator-only 语义正确；Vite 编译产物含 sourceCreate gate（活体 UI 走位归 lane5）

## 6. P1+P2 站位回归（引擎面）

| 断言 | 结果 |
|---|---|
| browse 模式 createSync（D2，跨 base creator 源读）→ 200 + 镜像拉数 | PASS |
| resync 复检：allow_sync 关 → 400 "no longer allowed on the source view" | PASS |
| resync 复检：browse 源权限降 no-access → **404 Base not found**（assertSourceReadAccess 语义）；恢复 creator → resync 200 | PASS |
| synced 写守卫：向 active 镜像插行 → 400 readonly（守卫链兜底，HTTP 侧不可写） | PASS |
| paused 守卫：freeze 后 resync/update → 400；resume → 200 | PASS |
| detach（D1）：200 → getSync 404 → synced:false → 列 readonly 全解（Title ro=false）→ 插行 200 可编辑 | PASS |
| deleteSync（D2）：200 → getSync 404 → 镜像表 meta 404 / base tables 列表无（trash 语义） | PASS |
| editor ACL 七端点：list / resolve-link / get / resync / detach / delete / patch / freeze 全 **403** | PASS |

editor ACL 首测一轮出现 resync/detach/delete 404（list/resolve 同轮 403）——两轮复测（含 bare POST 与带 body POST）**全 403，不可复现**，判定为该轮脚本环境伪影（token/时序），不列违反；归因注记：403 与 404 混合出现时建议未来 lane 直接复跑三轮再定性。

## 7. minor（1 项，观察级）

- **M-1｜shareViewUpdate 设密码未生效**：`PATCH /api/v2/meta/views/:id/share` body `{password}` 返 200 但 resolve 无密码仍返全量坐标（复现 1/1，时点在 uuid 已存在后）；改走 `PATCH /api/v2/meta/views/:id`（viewUpdate）`{password}` 即落库生效（bcrypt，resolve 密码矩阵随即全过）。归因：shareViewUpdate→View.update 的 `{...param.sharedView}` spread 理论上带 password、SharedViewReq schema 亦含 password 属性（swagger.json 实查），未定位到剔除点；测试 base 已清理无法当场重测。**非本轮修复面**（253c3b6ee5 未触 views.service），resolve/sourceSchema 对 view.password 的分支判定本身验证 pass（无密码→`{passwordProtected:true}` 零泄露 / 错密码 400 / 对密码 200，双端点矩阵全过）。建议：后续轮次建共享视图密码时统一走 viewUpdate 端点，并单独归因 shareViewUpdate 密码链路（上游 CE vs fork）。
- 附带实测备忘（非违反）：H1 初测曾出现「无密码 resolve 返全量」——根因即 M-1 密码未落（view.password 空），修复面之外；密码真正落库后该分支行为完全正确。

## 8. 质量门 —— 全绿

- `npx tsc --noEmit`：**exit 0**
- jest Fork 桶：**3 suites / 41 tests 全过**（exit 0）
- Vite URL 编译强验（`/_nuxt/@fs/`）：Overview.vue（R4 修复面）+ CreateNewSync.vue（向导 SFC）双 **200**，均返真实编译产物（createHotContext JS），Overview 产物含 sourceCreate gate

## 9. 结论与计数

| # | 级别 | 一句话 | 位置 |
|---|---|---|---|
| M-1 | minor | shareViewUpdate（PATCH views/:id/share）设密码未生效；viewUpdate 端点正常；非本轮修复面，密码分支判定本身 pass | packages/nocodb/src/services/views.service.ts:691 shareViewUpdate（归因待复现） |

R3 修复四项回归全过（M-1 hash URL / lane2 凭据剥离 / M-2 漂移日志 / lane5 Overview gate）；R4 四重点全过；P1+P2 引擎面站位零复现。**本路 0 error**，P2 连击计数不受阻。

## 证据索引

- 脚本：/tmp/f09p2r4l4/（env.sh、t1-setup.sh、t2-hashchain.sh、t3-addcol.sh、t4-drift.sh、t5-dualdel.sh、t6-guards.sh、ids.env、各步 json 输出）
- 质量门日志：/tmp/f09p2r4l4-tsc.log（exit 0）、/tmp/f09p2r4l4-jest.log（41/41）
- 漂移日志：/private/tmp/nocodb-internal.log（4:08:47 段，"Qty: bigint -> SingleLineText"）
- UI 截图：无（引擎路，camoufox 未动用）

## 清理

4 个测试 base（SRC/D1/D2/D3，全 `f09p2r4l4-` 前缀）经 f01e2e 软删 200，base 列表残留 0（D2 经 deleteSync→detach 流转后一并随 base 清除）；lane 账号 2 个留存（f09p2r4l4-api / f09p2r4l4-e，f01e2e 基建模式惯例，测试口令仅存 /tmp 脚本不入仓）；camoufox session f09p2r4l4 未创建（未动用）。
