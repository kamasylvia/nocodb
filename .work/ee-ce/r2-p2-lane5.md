# F09 P2 R2 — lane 5（UI + 修复回归重点路）报告

**结论：PASS — 0 error + 0 minor。** R1 五 error（E1/E2/E3/E4/M1）+ M3 菜单守卫全部修复实证（API 活体 + camoufox UI 活体）；P1 全矩阵回归无回归；删除流三腿照旧；质量门 tsc 0 + jest Fork 41/41 + 双 SFC Vite URL 200。

基线：HEAD 7db46fce29（R2 派遣批），修复批 366e0b7045。后端 :8080 行为级实证含修复批（R1 全部症状串零复现；dist mtime 23:39 早于 commit 01:24 属「先构建后提交」正常序，以行为为准）。前端 :3000 HMR 当前源码。

## 0. 修复点静态定位（只读核验，均带 [CE-EE] P2-R1 注记）

| 项 | 位置 | 修复形态 |
|---|---|---|
| E1/E2 | table-syncs.service.ts:456-468 | paste 分支自建 srcContext（view.fk_workspace_id/base_id）+ `Model.get(srcContext, view.fk_model_id)`——sourceTableId 不再需要，getColumns 用源 context |
| E3 | service.ts:918-925 | 映射行删除改按 `(fk_table_sync_id, source_column_id)` 键，不再依赖未 select 的 id |
| E4 | service.ts:929-954 | columnAdd 返回 Model 后按 title 从 `.columns` 取真列 id，取不到 fail-fast；readonly metaUpdate 打真列 id |
| M1 | service.ts:1141-1146 | 密码保护视图无密码时仅 `return { passwordProtected: true }` |
| M3 | SyncMenuOptions.vue:161-174 | Convert/Delete 菜单项 `v-if="sync.status !== Syncing"`（与 Sync now 同款藏匿） |
| 附赠 | service.ts:284-295 | sourceSchema paste 分支对齐 lane1 M1：错密码 400（原静默返全 schema），无密码仅 `{passwordProtected:true}` |

## 1. API 活体回归（账号 f09p2r2l5-api/api2；f01e2e 仅建 base + 邀请）

### E1+E2 paste 建同步（前端实发形态，无 sourceTableId）— 22/22
- `POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<URL>, sharedViewPassword}` **不带 sourceTableId** → 200（api2 对源 base 零权限，共享视图即凭证）
- R1 症状串「Shared view not found」「no syncable columns」**零命中**；无密码/错密码 400 负例保持
- mapping 落库：source_uuid = 视图 uuid；source_password_hash = bcrypt（$2*，非明文）；source_input_mode=paste
- 引擎经 paste 凭证拉数：full-create 3 行；resync 200 后数据对齐（row1.Note=n1）
- resolve-link URL/裸 uuid 双形 200；sourceSchema paste：无密码恰 `{"passwordProtected":true}`（1 键）/错密码 400/对密码 200+3 列

### E3/E4 selected_fields 传播 — 过
- 增腿（E4）：加 Note → 200 + 镜像列 readonly=true + **resync 后数据真进**（row1.Note=n1；源新插 row4 走 insert 路径 Note=n4）——R1「三次 resync 恒 null」不复现。getSync 只返 main mapping 无列级 dest_column_id，直证不可得；以数据流 + 静态修复点双证替代
- 减腿（E3）：减至 [Title] → **200 无 500**，Qty/Note 删 + 映射只剩 1 行 + selected_fields 持久化（无半态）；减后 null 全字段恢复 200（R1 半态下此路误判，现正常）+ resync 后 Qty/Note 数据回齐
- `[]` → 400 且列数不变；realtime → 400

### M1 resolveLink 密码三态 — 过
无密码：200 且响应**恰 1 键** `{passwordProtected:true}`，sourceTableTitle/sourceViewTitle/sourceTableId/sourceBaseId 零泄露（R1 泄露实锤处已闭）；错密码 400；对密码 200 + 源坐标（sourceTableId 对照命中）。

## 2. UI 活体（camoufox session `f09p2r2l5`，账号 f09p2r2l5-ui，base D3）

### 向导 paste 全流程（E1 用户可见面回归）— 过
step0 Browse/Paste 单选 → Paste 选中出 URL 输入 + optional 密码框 → 填 URL+密码 → Next **resolve 成功**进字段步 → 全字段默认 → 建表步（镜像名预填 + 双删除策略单选）→ Create sync → 成功 toast、镜像表入树、sync active 无错。全程无「Shared view not found」类红 toast（R1 E1 的 100% 踩中路径已闭）。向导不传 sourceTableId（行为实证：输入面仅 URL/密码）。另用大表视图（无密码变体）复走全流程亦成。

### M3 Syncing 态菜单守卫 — 过（活体命中）
大表（3000 行）向导建同步瞬间自动开其树菜单：菜单仅渲染 **status 行「Syncing」**，sync-now/convert/delete **不在 DOM**（testid 枚举实证 + 截图）；job 完成后重开菜单恢复全项（Synced table + Sync now + Pause + Convert to regular table + Delete sync）。菜单 open 时 load() 重取状态，无 R5 状态冻结回归。

### 删除流三腿 — 全过
- **leg1（active 删 + 有剩余）**：删当前打开的镜像 → 确认弹窗（sync 标题 + 红 Delete sync）→ 确认 → **重定向到剩余表**（URL 切到另一镜像），被删表出树
- **leg2（唯一表删）**：删最后镜像 → **重定向 base home**（URL `/nc/<baseId>` + 空态卡片回归）
- **leg3（非 active 删）**：停在 aux 表时删另一镜像 → **不重定向**（留在 aux），被删表出树
- 后端闭环佐证：三腿均在 `await remove()` 成功后才执行重定向/刷新代码；API 面 deleteSync → getSync 404（T3f）。中途一次「D3 syncs=2」警报经查为**测量事故**（详见 §5），非孤儿 sync

### 数据面佐证
源加行 → UI Sync now → 网格 2 records（Qty/Note 列值活体可见）；API 对照镜像行 Title=row10/11 + RemoteId=5/6 键控正确。大镜像 3K records 网格可见（向导 + 引擎大表 e2e）。

## 3. P1 全矩阵回归 — 过（API 实测 31 项断言 + 策略重测 3 项）

- 引擎 e2e：full-create（RemoteId 键控）、resync upsert；**双删除策略**：delete（源删行 → 镜像物理删）、mark_deleted（行保留 + RemoteDeleted=true）各独立样本实证
- freeze/resume：freeze 200 → paused → paused 下 resync 400 → resume 200 → active
- 灰区复检：allow_sync 关 → paste sync resync 400；复开 → 200
- ACL：无关用户（ui，仅 D3 owner）对 D2 十一端点（list/get/source-schema/resolve-link/create/update/delete/resync/freeze/resume/detach 取样）全 403；匿名 list/resolve 401；update 探针后标题未被污染
- 付费锁：syncTrigger=realtime 400；deleteSync：200 + getSync 404 + 镜像出表清单（进 trash 语义）；detach：200 + synced=false + 列 readonly 解（改名 200）+ 行可插

## 4. 质量门

- `tsc --noEmit`（packages/nocodb）exit 0
- jest Fork 桶（全 testRegex）：3 suites / **41 tests 全过**，exit 0
- Vite URL 法：`/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` 200 + `/_nuxt/components/project/Action/CreateNewSync.vue` 200（注意：向导 SFC 实际路径在 `project/Action/`，R1 报告所写 `project/Sync/` 路径 404，下轮引用请更正）

## 5. 测量事故记录（不计 issue，防 downstream 误判）

1. **「D3 syncs=2」假警报**：清理阶段用 env.sh 里不存在的 `$EMU` 变量（实为 setup.sh 局部变量）→ signin 空邮箱 401 → `xc-auth: null` → 响应为错误对象 `{"error","message"}`，`jq 'length'` = 键数 2。真实形态已实证：list 端点返数组 `[]`、tables 端点返 `{"list":[]}`。教训：env.sh 应固化测试账号邮箱；list 类断言先验 shape。
2. 脚本级已修正的断言串笔误 3 处（SS 拼接串/want=33 应为 11/单行 DELETE 路由 404 需用批删+body——后者与 R1 lane5 记录同款坑），均已当场重测，不影响结论。
3. UI 登录会使同账号既有 API token 失效（token_version 机制）：TU 在浏览器登录后作废属预期，API 核验移至 UI 段结束后重取。

## 6. 测试资产与清理

- 全部测试资源 `f09p2r2l5-` 前缀；5 个 base（src/d1/d2/d3/d5）已删（200），workspace 零残留；大表 3000 行随 src base 删除
- 测试账号 3 枚（api/api2/ui）留存未删（沿用 R1 惯例，P1 已知噪音项）
- 截图 `/tmp/f09p2r2l5/shots/`（ui-menu-syncing-big.png = M3 活体；ui-menu-active.png + ui-small-resynced.png = Active 全菜单；ui-delete-modal.png + ui-leg1/2/3 = 删除流三腿；ui-big-grid.png = 3K records；ui-step0-paste.png = paste 输入面）；脚本 `/tmp/f09p2r2l5/{setup,t1,t2,t3}.sh`、质量门日志 tsc.log/jest.log
- camoufox session f09p2r2l5 已关闭
