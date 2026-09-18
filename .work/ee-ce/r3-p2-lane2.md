# R3 P2 站位回归报告 — lane 2（f09p2r3l2-*）

**结论：PASS — 0 error + 1 minor**

- 审查基线：366e0b7045（R1 修复批，工作树零源码变更；HEAD 7db46fce29 仅 dispatch）
- 后端 :8080 = pid 33253（01:24:06 启动）运行 dist（mtime 23:39），dist 内 grep P2/R1 标记全在（sourceInputMode×4 / source_uuid×4 / source_password_hash×2 / bypassSyncedFieldGuard×4 / resync 复检文案×1）
- 隔离声明：未读任何他路 R3 报告；测试数据全 `f09p2r3l2-` 前缀；测试 base 两个已删（200）；UI/API 账号分离；仅写本报告与 /tmp/r3p2l2

## 质量门（3/3 绿）

| 门 | 结果 |
|---|---|
| tsc --noEmit（packages/nocodb） | exit 0 |
| jest Fork 桶（testRegex Fork/Integration/Source） | 3 suites / **41/41 passed**（table-syncs.Fork.spec.ts 含） |
| Vite URL 编译门 | CreateNewSync.vue 200 / SyncMenuOptions.vue 200 |

## P2 六项（API 实测，全部活体）

1. **paste 模式全链** ✓
   - resolveLink 裸 uuid → 全量坐标；真实 share URL（`/nc/grid/<uuid>`，URL 形态经前端 SharePage.vue:393 确认）→ 解析成功；protected 无密码 → 仅 `{passwordProtected:true}`（无 title 泄露，R1 E-fix 回归通过）；错密码 → 400
   - sourceSchema paste 分支：protected 无密码 → `{passwordProtected:true}`；带密码 → mode=paste + 3 列预览 + uuid
   - createSync `sourceInputMode:'paste'`（不带 sourceTableId）+ uuid+密码 → 200 → 引擎 full-create 3 行全进（row1/2/3 Name/Qty/Note 对照一致）；mapping 落 source_uuid + source_password_hash（bcrypt `$2a$10$…`，明文未落库）
   - 守卫：无密码 createSync protected → 400；错密码 → 400
2. **selected_fields 增删传播** ✓（browse 模式 sync）
   - 建 `[Name,Qty]` → 镜像两列 readonly=true；PATCH 加 Note → 新列 readonly=true（metaUpdate 强制补丁生效）+ mapping 新行 + **resync 后 Note 数据真实进**（row1/2/3 → note1/2/3，R1 E4 dest_column_id 修复活体）；PATCH 减列 → 列删 + mapping 删（无 500，R1 E2 修复活体）；`[]` → 400；未知字段 → 400；`null` → 全字段（Qty/Note 重建）
3. **源列类型漂移** ✓：源 Qty Number→SingleLineText（dt text）→ resync → 镜像 Qty uidt/dt 跟随、readonly 保持 true、数据重刷为字符串（"1"/"2"/"3"）
4. **detach 转正** ✓：paste sync detach → `{ok:true}`；getSync 404；镜像 synced=false + readonly 列清零；手插行成功（where 回读确认写入）；原 3 行数据保留
5. **resync 复检** ✓：
   - allow_sync 关 → resync 400「no longer allowed」；恢复后正常
   - browse 源权限显式 no-access 用户 resync → **404 ERR_BASE_NOT_FOUND**（对照：同用户源表数据读 403，拒绝语义一致）
   - ws 继承澄清（非问题）：行 roles=null 的 ws-creator 用户 resync 200——与该用户直接读源数据 200 一致，属平台 workspace 继承语义（BaseUser.ts path 2），非绕过
   - paste 凭持久凭证：无源权限用户（源 no-access）resolveLink/createSync/resync paste sync 全 200，引擎拉数 3 行
6. **原子性** ✓（代码审）：createSync 主体包 try/catch，tableCreate 后任一失败 → best-effort `tableDelete(forceDeleteSyncs)` + rethrow（table-syncs.service.ts:721-734）；post-tableCreate 失败点（mapping insert/GVC patch/job enqueue）无 API 可稳定构造，未实测

## P1 全矩阵回归

- **引擎 e2e**：full-create（6002 行镜像 count 与源一致）；resync upsert（源 row1 改值 → 镜像跟随）；mark_deleted 策略（源删行 → 镜像行保留 RemoteDeleted=true）；delete 策略（源删行 → 镜像行删除）；PATCH on_delete_action 切换 200；freeze → paused + resync 400「paused」+ update 400 + freeze 重复 400「already paused」；resume → active + 重复 resume 400「not paused」；deleteSync（active 态）→ sync 404 + 镜像 404（trash 语义）
- **E1 六格互斥**（syncing 窗口内，6002 行 full-create 期间）：update 400 / resync 400 / freeze 400 / resume 400 / deleteSync 400「Cannot delete a sync while it is running」/ detach 400；同 base 第二 createSync 400「Another table sync is still running」
- **ACL**（直接 curl 复验）：editor/viewer 对 list/get/create/source-schema/update/resync/freeze/resume/resolve-link/detach/delete 全 **403**（ERR_FORBIDDEN 文案逐个核过）；无关系用户（ws no-access 无 base 行）全 403
- **守卫链**：editor 写镜像 insert/update 400（readonly 守卫）、owner 写镜像同 400（与角色无关的镜像只读层）；RemoteId/RemoteDeleted = system:true + readonly:true + GVC show:false 三保险（fk_column_id 映射核对）
- **realtime 锁**：syncTrigger=realtime → 400「Only the manual sync trigger is supported」
- **F 系探针**：F05 variables 200；F02 permissions 400（业务校验，端点在）；F07 snapshots 探针 404（探针路径疑非本仓实现路径，非 F09 回归项，不判）

## UI 活体（camoufox session f09p2r3l2，UI 账号 f09p2r3l2-ui@ dst owner）

1. **向导 paste 全流程** ✓：空 base 页「NocoDB Sync」入口 → step0 **Browse/Paste link 单选在** → Paste 输入 URL + 密码（optional 框在）→ Next 触发 resolvePasteLink 成功 → 字段步（All fields 默认）→ 策略步（Deleted/Retained）→ Create sync → 镜像表进树
2. **树菜单三态** ✓：
   - active：Sync now / Pause sync / **Convert to regular table** / Delete sync 全在
   - **Syncing**：菜单收敛为 Rename/icon/Duplicate/description/permissions 五项——**Sync now/Pause/Convert/Delete 全隐藏**（M3 守卫 UI 侧活体）
   - paused：**Resume sync** 替代 Pause，Convert/Delete 在
3. **Convert 转正流** ✓：点击后 sync 列表该项消失、表留树（removeMeta + loadTables 生效）
4. **Delete sync 流** ✓：确认弹窗（Cancel/Delete sync）→ 确认 → 树表消失 + sync 列表收敛
5. Nuxt overlay 无

## Minor（1）

- **M-1（低危，信息披露面）**：`getSync`/`listSyncs` API 响应将 `source_password_hash`（bcrypt）一并返回给 dst base 的 manager 类角色。hash 单向不可逆、端点本身 owner/creator 才可达，泄露面有限；但该字段属持久凭证材料，响应体省略更稳（paste 凭证轮换功能未来上线时会更有意义）。不构成安全违反，建议后续批顺手在 toType/响应组装处剥离。

## 测试函数注记（非产品问题）

- 初轮 ACL 矩阵脚本中 zsh 引号展开缺陷导致 create/update/resolve/schema 误报 400；改直接 curl 逐个复验均为 403，已在 ACL 段更正
- 首轮 E1 六格两次因 syncing 窗口未形成/已关闭而打出 200，属测试时机问题；6002 行 full-create 真窗口下六格全部 400 判定成立

## 清理

- 测试 base `f09p2r3l2-src-1789755249` / `f09p2r3l2-dst-1789755249` 均 DELETE 200（含镜像随 trash）
- 账号 f09p2r3l2-{api,x,probe,ui,ed,vw,editor,viewer}@… 无 super 凭证不可删，与既有「dev 库测试账号」历史项同例留存
