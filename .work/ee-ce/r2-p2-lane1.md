# F09 P2 R2 修复回归会审 lane1 报告（账号 f09p2r2l1-*，基线 366e0b7045）

结论头：**PASS — 0 error + 0 minor**

R1 五 error 全部活体验证已修，无复发、无新 error。基线核验：HEAD=366e0b7045；:8080 进程 pid 33253（启动 01:24:06）晚于 dist mtime 23:39，dist 含 P2 特征（sourceInputMode×4 / resolveLink×6 / detach×22）+ R1 修复特征（"Failed to create mirror column for"×1、E1 修复注释×1）→ 运行 dist = 修复后代码。

## R2 重点一：E1+E2 paste createSync（R1 双断点）——PASS

- **前端实发形态（无 sourceTableId）**`POST /table-syncs {sourceInputMode:'paste', sharedViewUrl:<uuid>}` → 200 建镜像。三个活体样本：无密码（api）、带密码（api，`sharedViewPassword` 传对）、无源权限账号（api2 对源 base 实测 403）——全部成功。
- **引擎拉数**：三镜像各 3 行、值精确对照（row1/Qty1, row2/Qty2, row3/Qty3）。
- **mapping 落库**：`source_uuid` = 视图 uuid；`source_password_hash` = `$2a$10$4cT6…` bcrypt 串（明文不落库，R1 E-blocked 断言本轮补齐）。
- **R1 症状零复现**：无 "Shared view not found"、无 "no syncable columns"。
- 源码对照：service.ts:463-469 `srcContext` 统一构造 + `Model.get(srcContext, view.fk_model_id)`（E1 回退修）+ `getColumns(srcContext)`（E2 修）；resolve-link/sourceSchema paste 分支复检正常（URL 形/裸 uuid 形/非法输入 400）。
- **paste resync 不复检 base 权限（R1 E-blocked 补测）**：api2 无源权限 → resolve 200 / createSync 200 / 镜像 3 行——EE paste 语义（share link 即凭证）活体成立。

## R2 重点二：E3 减腿 / E4 增腿——PASS

干净 browse 样本（selectedFields:['Title'] → full-create 3 行）上：

- **E4 增腿**：PATCH `selected_fields:["Title","Qty"]` → 200，镜像 Qty 列出现且 readonly=true；**resync 后 Qty 数据真实进**（row2=2，全列 1,2,3）——R1「dest_column_id 落 model id 致恒 null」症状消除。源码：service.ts:930-937 `addedModel.columns.find(title)` + fail fast（"Failed to create mirror column"），insertColumnMappings 落真实列 id。
- **E3 减腿**：PATCH `selected_fields:["Title"]` → **200**（R1 500 Undefined binding）；镜像 Qty 列删。**半态残留不复现**：减腿后 `selected_fields:null` 增回 → Qty/Note 列重新补建且数据进——若减腿映射残留，toAdd 会误判「已映射」不补建（R1 半态病理），实测行为证明映射删干净。
- 边界：`[]` → 400；`null` → 200 全字段持久化 + 补建 + resync 数据进（Qty=3/Note=n3 对照）。
- updateSync 后 sync 健康：源增 row4 → resync 4 行、status active、last_error null。

## R2 重点三：M1 resolveLink 密码保护——PASS

设密视图：无密码 resolve → **仅 `{passwordProtected:true}` 单键**（sourceTableTitle/sourceViewTitle/sourceBaseId 零泄露，keys 实测恰为 `passwordProtected`）；错密码 → 400；对密码 → `passwordProtected:false` + 全量坐标。源码 service.ts:1138-1140 对齐 sourceSchema 形状。测试后密码已清（`password:""`）。

## R2 重点四：M3 Syncing 态菜单守卫——PASS（UI 活体）

4952 行大表 resync 提供窗口，时序抓帧（菜单 open 时 `load()` 重拉 status，useTableSync 无轮询 → 必须.Syncing 中开菜单）：

- **Syncing 帧**（shot-menu-syncing2.png）：菜单仅 Rename/Change icon/Duplicate/Edit description/Edit permissions + Syncing 状态行——**Convert to regular table 与 Delete sync 双消失**（连同 Sync now/Pause sync，v-if 生效）。
- **active 对照帧**（shot-menu-active.png）：job 完成重开菜单，全项回归（含 Convert/Delete）。
- 手段说明：树菜单三点按钮受 CSS group-hover 显隐（headless 无法触发），以 DOM style 注入强制显示后点击——仅绕显隐，菜单内容逻辑（load fetch + v-if）未被绕过。
- 后端守卫（Syncing 拒 update/resync/detach/delete 400）独立 API 实测见下。

## R2 重点五：P1 全矩阵回归——PASS

- **引擎 e2e**：full-create（RemoteId 键控）✓；**双删除策略**：delete（源删 row4 → resync 镜像物理删回 3 行）/ mark_deleted（源删 row3 → 行留 `RemoteDeleted=true`，行数不变）；freeze → paused（resync 400 / update 400）→ resume 恢复；deleteSync → 200 + get 404 + 镜像移出 tables 列表。
- **detach 正向抽测**（paste sync）：synced true→false、Title readonly true→false、getSync 404、镜像可编辑（insert 200）。
- **ACL 十一端点矩阵**（editor2 对 dst base）：list/get/source-schema/create/update/resync/freeze/resume/resolve-link/detach/delete **全 403**；匿名 401；owner 全通。editor 直写镜像表 400；owner 直写镜像也 400（readonly 守卫）。
- **付费锁**：`syncTrigger:"realtime"` → 400。
- **守卫链**：镜像列 readonly=true（meta API）；系统列行为正常（RemoteId/RemoteDeleted 在记录中不干扰业务列读写）。

## UI 段（camoufox session f09p2r2l1，账号 f09p2r2l1-ui）

**paste 向导全流程活体 PASS**：base 首页 NocoDB Sync 卡片 → 向导 step0 **Browse/Paste link 单选在位**（shot-wizard-step0.png）→ Paste link → Shared view URL 输入（+Password optional 框动态出现）→ Next（resolve + loadSchema）→ Fields to sync → Sync settings（Manual + 双删除策略）→ **Create sync 成功**：树出新镜像 `f09p2r2l1_src_tbl`，无红 toast（R1 此步必 400 "Shared view not found"）；API 侧核验该 sync `source_input_mode:paste / status:active / last_error:null`，镜像 **4952 行全量拉齐**（row1/row2 值对照正确）。

## 质量门

- `tsc --noEmit` exit 0
- jest Fork 桶：**3 suites / 41 tests 全过**（TableSyncProcessor ERROR 日志为 spec 内注入的失败用例 "db exploded"，非环境错误）
- Vite URL 法：SyncMenuOptions.vue / CreateNewSync.vue（components/project/Action/）经 `/_nuxt/@fs/...` 均 200 且返回编译产物 JS
- 测试资源已清理：两 base（src/dst）DELETE 200，视图密码清除，camoufox session 关闭

## 观察项（不计 issue）

- getSync 响应 mappings 仅含 main 行（列映射不外显 API）——E3 映射一致性以行为证据闭环（见 R2 重点二）。
- R1 M2（漂移传播当轮 baseModel 未重建、写入 cast 用旧类型，minor）不在本轮五项修复面内，未复测，维持 R1 记录。
- paste sync 建立后源视图后设密码：持久凭证仍有效（resync 未复验 hash）——R1 已记观察项，EE 语义未定，规格未要求。
- 基建摩擦（非产品问题）：被邀请用户 signin 被堵（本地无邮件服务），测试账号须「先 signup 后邀请」；admin 改密不解除邀请态。

## 证据索引

- 截图（.work/ee-ce/）：r2p2l1-shot-menu-syncing2.png（M3 Syncing 帧）/ r2p2l1-shot-menu-active.png（M3 active 对照）/ r2p2l1-shot-wizard-step0.png（Browse/Paste 单选）/ r2p2l1-shot-wizard-schema.png / r2p2l1-shot-wizard-final.png / r2p2l1-shot-wizard-created.png（UI paste 全流程）
- 脚本（.work/ee-ce/）：r2p2l1-lib.sh / r2p2l1-setup.sh / r2p2l1-t1.sh / r2p2l1-t1b.sh（paste 链 + hash + 无源权限全链）/ r2p2l1-t2.sh（selected_fields）/ r2p2l1-t3.sh（P1 回归）
- 日志：r2p2l1-tsc.log（exit 0）/ r2p2l1-jest.log（41/41）
