# F09 P2 实现自述（生命周期完备，2026-09-18 21:4x）

HEAD（实现批）；基线 = F09 P1 pass（5e3d736b2a）。质量门：tsc 0 + jest Fork 41/41 + 双 SFC Vite URL 200。

## 交付面

1. **paste 模式**（跨 base 共享视图 URL 同步）：createSync 接受 `sourceInputMode:'paste'` + `sharedViewUrl`/`sharedViewPassword`；uuid 解析（URL 或裸 uuid）→ View.getByUUID → allow_sync 强制 + bcrypt 密码校验；映射持久化 `source_uuid` + `source_password_hash`（明文不落库）；resolveLink 端点实装（向导 resolve 预览，返回 source 坐标 + passwordProtected 标志）；sourceSchema 支持 paste 分支（`{sharedViewUrl}` 预览，密码保护未给密码时返回 `{passwordProtected:true}`）
2. **selected_fields 变更传播**：updateSync 接受 `selected_fields`（null=全字段/数组=白名单）；desired 集合对比 column_mappings——**删腿**：columnDelete(forceDeleteSystem+skipTrash) + 逐行删映射；**增腿**：columnAdd(readonly payload) + metaUpdate 强制 readonly + 插映射；空数组/null 语义校验（[] → 400）
3. **源列类型漂移传播**（processor）：resync 时比对 srcCol.uidt/dt vs destCol——漂移即 columnUpdate(bypassSyncedFieldGuard=true)（引擎权威通道）+ 日志；失败 warn 不阻塞本轮数据同步
4. **detach（转正）**：`POST .../table-syncs/:id/detach`（tableSyncDelete ACL）——Model.updateSynced(false) + 全列 readonly=false（直 meta）+ COLUMN:list 缓存失效 + 删映射 + 删 sync 行；镜像表与数据保留为普通可编辑表
5. **灰区修复**：resync 前置复检（allow_sync 仍在 + browse 模式源读权限断言；paste 凭持久凭证）；createSync 原子性（tableCreate 后任意失败 → best-effort tableDelete 镜像 + rethrow）；selectedFields:[] → 400
6. **前端**：向导 step0 Browse/Paste 单选 + URL/密码输入 + resolvePasteLink→loadSchema 复用后续步骤；create 体分模式传参；树菜单「Convert to regular table」项（onDetach：detach + removeMeta + loadTables）

## 测试基建

- jest：`__mocks__`（nanoid/request-filtering-agent ESM stub + @noco-local-integrations/core stub）+ jest.config moduleNameMapper 三条——columns.service 引入链首次进 Fork spec
- spec 更新：resync 用例补 mapping/View/BaseUser mock；selected_fields 用例改为断言空数组拒绝；构造函数补 columnsService stub
