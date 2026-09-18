# F09 P2 R1 会审 lane1 报告（账号 f09p2r1l1-a，基线 a4959c27cd）

结论头：2 error + 2 minor

基线/dist：HEAD=a4959c27cd；dist main.js 含 P2 标记（sourceInputMode×4/resolveLink×6/bypassSyncedFieldGuard×4/updateSynced×2/detach×22）。后端 :8080 活体实测。camoufox session 未用（前端 :3000/:5173 全 000，下见 M2）。

## P1 resolve-link→create 实测（paste 双分支）
- resolve-link uuid/URL 双形 PASS（passwordProtected:false）；bogus→400；editor→403；匿名→401
- source-schema paste PASS（列 Title/Qty/Note 全）
- 密码分支 resolve-link PASS：设密后 无密码→pp True；错密码→400；对密码→pp False；清密恢复

## E1（error）：paste createSync 双路全 400，P2 头条功能不可用
- 无 sourceTableId：400 `Shared view not found`
- 带 sourceTableId（前端 resolvePasteLink 后必带，见 CreateNewSync.vue:184）：400 `Source table has no syncable columns`
- 根因（源码）：service.ts:460-465 paste 分支 `Model.get({...context, base_id: view.base_id}, sourceTableId)` 后 `getColumns(context)` 用 dest context 取源表列 → 缓存/空间错位致 mirrorable 空；且无 sourceTableId 时 `Model.get(ctx, undefined)` 直接 null。browse 同表同账号对照建 sync 正常（full-create 3 行），排除数据问题
- 复现：`POST /table-syncs {sourceInputMode:paste, sharedViewUrl:<uuid>[, sourceTableId]}`

## E2（error）：selected_fields 增减传播必崩（SQL undefined id 删除）
- PATCH `{"selected_fields":["Title"]}` → 500 innerError：`delete from nc_table_sync_column_mappings where id=? — Undefined binding [id]`
- 根因：TableSync.listColumnMappings 只 select(source_column_id,dest_column_id)，service.ts:890-905 却按 `m.id` 逐行删。增腿/减腿同路全崩；sync 状态保持 active/sel null（失败原子，未半写）
- `[]`→400 PASS（判对分支）

## PASS 段
- 类型漂移：源 Title SLT→LongText，resync 后镜像跟随 LongText，status active/last_error null/数据 3 行完好（PASS；Qty Number 列曾消失为另一证据：mirror 列清单无 Qty，疑 E2 失败 UPDATE 副作用/旧映射残留，记 M1 待查）
- detach：synced true→false；Title/Note readonly true→false；sync 404；数据 3 行保留；insert→200 可编辑（PASS）
- 灰区 resync 复检：allow_sync 关→400；重开→200 + active（PASS）
- ACL/守卫：editor list/get/schema/resync/detach 全 403；匿名 401；paused 下 update 拒；镜像 insert 400（PASS）
- 质量门：tsc --noEmit exit 0；jest table-syncs.Fork.spec 15/15 PASS
- 原子清理/失败 warn 通道：代码审（service.ts:604-733 best-effort tableDelete；processor:174-178 warn 不阻塞）+ 说明：难构造，未实爆

## M1（minor）：schema 密码分支与 create 不一致
- source-schema paste 错密码时静默返回全 schema（无 400），而 resolve-link/create 均 400。建议对齐 400

## M2（minor）：UI 段活体缺席
- 前端 dev :3000/:5173 全 000；headless 浏览器仅探活后端根。CreateNewSync paste 单选/URL+密码/resolve→loadSchema 分支与 SyncMenuOptions onDetach+detach() 源码在位（静态 PASS），活体截图缺席。另 E1 意味着 UI paste 全流程 Create 步必 400（E1 子项，不另计）

## 复测资产（lane 前缀外仅读，写均为自建 base）
- src base pn3yjo2wpte3f4q / dest pazsadh6br6g9cw；超管 f01e2e 建 base + invite lane 为 owner；editor f09p2r1l1-e 仅 ACL 探针
- sync tssvu2roti3g8pymt（已 detach，转正表 mj7eh1gp2s3rn4o 留存可编辑）；acl_sync tssihwxp2cy7zglxh（active，镜 msjlnqyb0cpqi6y）
