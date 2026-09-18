# F09 P2 R4 — lane 3（安全审计重点路）报告

**结论：PASS — 0 error + 0 minor。**

R3 修复批 253c3b6ee5 四项修复回归全过（活体）；lane3 安全四重点（响应凭据剥离 / paste 凭据面 / resolveLink 密码三态 / detach ACL）全数实测通过；质量门全绿。审查时间 2026-09-19 04:00-04:40，后端 :8080 = pid 96879 运行 dist（进程启动 03:51 > dist mtime 03:00；R3 特征 grep：source_uuid×6 / source_password_hash×4 / sourceInputMode×4 / sharedViewUrl×5 / passwordProtected×7 / bypassSyncedFieldGuard×4 / detach×22 / "never expose the share credential"×1）。

## 0. 环境与账号

- f01e2e@ 仅作基建（建 4 base + 邀请；token_version 多 lane 互踢，现取现用）；lane 资源全 `f09p2r4l3-*` 前缀
- SRC base（f01e2e 持有，无人有源权限——paste 纯共享凭证语义；源表 3 列 3 行；视图 v1 allow_sync+密码、视图 v2 allow_sync 无密码对照）
- D1（api owner，API 主链）/ D2（api 邀入 owner 建 sync，eapi editor ACL 面，ui owner UI 树菜单）/ D3（ui owner UI 向导建 sync，e editor 卡 gate 面）
- 账号 4 个 UI/API 严格分离：f09p2r4l3-api / -ui / -e / -eapi；camoufox session `f09p2r4l3` 专属，全程未动 default

## 1. R4 重点 1：editor Overview 卡不可见（R3 lane5 error 修复回归）—— 过

- **editor 面**（e 账号，D3 空镜像 base）：动作面板断言 `syncCard=false`（「NocoDB Sync」卡不可见）；相邻 Create New Table / Import Data / Connect External 卡因 `isUIAllowed('tableCreate')` 同隐（role 管线一致）——`Overview.vue` 新增 `isUIAllowed('sourceCreate')` gate 活体生效。截图 `r4-editor-d3-home.png`
- **creator 面**（ui 账号，D3）：卡可见（`r4-d3-owner-card.png`）且可点开向导走完全程——修复未误伤 creator
- editor 树菜单抽测：D3 镜像表三点菜单仅 `TABLE ID` 头面板，Sync 组整块不渲染（useTableSync 403 → sync=null gate）

## 2. R4 重点 2：hash 形共享 URL —— 过

`http://localhost:3000/#/nc/grid/<uuid>` 形态（extractSharedViewUuid hash 段解析）：

| 断言 | 结果 |
|---|---|
| resolveLink hash+密码 → 200 全量坐标 | PASS |
| resolveLink hash 无密码视图 → 200 坐标（与 path 形对照一致） | PASS |
| sourceSchema hash+密码 → 200（columns=Title/Qty/Note） | PASS |
| createSync paste hash 形态 → 200 + 引擎拉数 3 行 | PASS |
| UI 向导贴 hash URL：密码框现（v-if=sharedViewUrl）→ resolve → step1 → Create → 镜像 3 行全数据 | PASS |

R3 lane4 M-1（400 症状）不复现。

## 3. R4 重点 3：响应凭据剥离（lane3 安全核心）—— 过

**源码审**：`listSyncs`/`getSync` 双点逐 mapping `delete source_uuid/source_password_hash`（table-syncs.service.ts:257-262/275-279）；`TableSync.listMappings` 为 SELECT*（剥离必要且充分）；所有 sync 返回路径（createSync/updateSync/freeze/resume）均经 `this.getSync()` 单一出口——剥离覆盖闭合。

**活体**（三 base 断言 JSON 序列化后字符串扫描）：

| 响应 | leak_uuid | leak_hash |
|---|---|---|
| createSync（D1，hash 形 paste） | False | False |
| getSync（D1） | False | False |
| listSyncs（D1/D2/D3） | False | False |
| updateSync selected_fields 减列（D1） | False | False |
| createSync（D3，UI 向导所建） | False | False |

mapping 行保留键集合理（base_id/source_*/dest_*/role/时间戳，无凭据键）。

## 4. R4 重点 4：漂移日志旧值->新值（R3 lane4 M-2 修复回归）—— 过

活体：D1 重建 sync（镜像 Qty 基线 Number/int）→ 源 Qty Number→LongText → resync → 镜像跟随 `('Qty','LongText')`；后端日志：

```
Table sync tssobgbeo9pfag8vv: propagated column type change Qty: int -> LongText
```

旧值（int）在前、新值（LongText）在后 ✓（oldType 先捕后变异，processor.ts:159-176）。

## 5. lane3 安全重点补充实测

### 5.1 resolveLink 密码三态 —— 过

| 态 | 结果 |
|---|---|
| 密码视图 + 不给密码 → `{"passwordProtected":true}`，键集合仅此一键，零 title/base 泄露（R1 M1 回归） | PASS |
| 密码视图 + 错密码 → 400 `Invalid shared view password` | PASS |
| 密码视图 + 对密码 → 200 全量坐标（base/table/view/title，passwordProtected:false） | PASS |
| 无密码视图 → 200 直接坐标（path/hash 双形态） | PASS |
| sourceSchema 密码视图不给密码 → `{passwordProtected:true}` | PASS |

### 5.2 paste 凭据面 —— 过

- **落库**：mapping 仅在 paste 分支写 `source_uuid`+`source_password_hash`，后者 = view.password（bcrypt hash）本体，明文永不落库（insertMainMapping，service:759-793；源码审）
- **日志**：后端日志（/private/tmp/nocodb-internal.log）全程窗口四重 grep 零命中——明文密码 `0`、`source_password_hash` 键名 `0`、`source_uuid` 键名 `0`、本 lane uuid 值 `0`
- **前端**：密码走 POST body 不入 URL；`a-input-password` 遮蔽渲染（向导实测 eye-invisible）；对话框关闭置 undefined（CreateNewSync.vue:211-212）
- **前端无凭据回显**：resolve 后 step1/step2 快照无密码回显

### 5.3 detach ACL —— 过

- controller 绑 `@Acl('tableSyncDelete')`（controller:191-193），editor 403 文案正确落 delete 语义：`Forbidden - You do not have permission to delete a table sync with the roles: Editor`
- owner detach → 200 `{ok:true,tableId}` → getSync 404 → `synced=false` → 列 12 保留 → 数据 3 行保留可编辑
- 403 body 零坐标泄露（仅角色文案）；匿名 listSyncs → 401

## 6. P1+P2 全矩阵站位 —— 过

| 断言 | 结果 |
|---|---|
| selected_fields 减列 → 200 无 500 + 镜像列删（R1 E3 回归） | PASS |
| 增列回 → 200 + 列重建 + resync 后 **Note 数据 n1/n2/n3 真实进数**（R1 E4 回归） | PASS |
| 空数组 → 400；null → 200 全字段 | PASS |
| 类型漂移：镜像 uidt 跟随源（Number→LongText 活体） | PASS |
| resync 复检：allow_sync 关 → 400 精确文案；恢复 → 200 | PASS |
| detach → 200/404/synced:false/数据保留（上节） | PASS |
| paste resync（无源 base 权限，凭持久凭证）→ 200 | PASS |
| ACL 十一端点（list/get/resolve-link/source-schema/create/update/resync/freeze/resume/detach/delete）editor **全 403** | PASS |
| editor 攻击面复核：update 篡改 title / delete 后 sync 完好（title/status 未动） | PASS |
| 引擎 e2e：full-create 3 行（D1/D3 双 base）+ resync upsert + 漂移传播 | PASS |
| 树菜单三态：Active（Synced table 徽标 + Sync now/Pause/Convert/Delete sync，无 Delete table）/ Paused（Resume sync 翻转，免 reload）活体 | PASS |
| Syncing 竞态 UI 抓帧本轮未重打（R3 已验 + jest Fork 桶断言在跑；站位不重开已闭环项） | 站位 |
| 守卫链：Syncing 中 update/delete/detach/resync 400（jest Fork 桶 41/41 覆盖） | 站位 |

## 7. 质量门 —— 全绿

- `tsc --noEmit` exit 0
- jest Fork 桶：**3 suites / 41 tests 全过**（exit 0）
- Vite URL 编译强验（`/_nuxt/@fs/`）：CreateNewSync.vue 200 / Overview.vue 200 / SyncMenuOptions.vue（TreeView/Table/ 路径）200，均 createHotContext 真编译产物

## 8. 源码审备注（不计 violation）

1. resolveLink/sourceSchema 检查顺序：allow_sync 校验先于密码校验——allow_sync 关时无密码请求即报「Sync is not allowed」。暴露的仅是共享视图 allow_sync 布尔状态（共享链接语义下非机密）；五轮复审历史均未列，不构成泄露渠道。
2. sourceSchema paste 返回 `sourceBase.title=base_id`（uuid 本体，非真实标题）——泄露弱化方向，安全无害。
3. updateSync 字段传播不复核 browse 源读权限（ACL 已限 creator+；owner 被移出源 base 后理论上可经 unknown-field 报错探源列名——需双 owner 构造，构造成本高于收益，R1-R5 均未列；记录备查）。

## 9. 结论与计数

| 级别 | 数量 |
|---|---|
| error | **0** |
| minor | **0** |

R3 修复批四项（creator gate / hash URL / 漂移日志 / 响应剥离）修复回归全部活体通过；安全四重点零缺陷。

## 证据索引

- 截图：/tmp/f09p2r4l3/shots/（r4-d3-owner-card / r4-wizard-hash-step1 / r4-d3-mirror-created / r4-d3-mirror-grid / r4-menu-active-full / r4-menu-paused / r4-editor-d3-home / r4-editor-d2-tree-menu）
- 脚本与响应：/tmp/f09p2r4l3/（setup.sh、t1.sh-t5b.sh、env.sh、create-resp.json、get-resp.json、acl-*.json）
- 质量门日志：/tmp/f09p2r4l3-tsc.log、/tmp/f09p2r4l3-jest.log
- 后端日志凭据扫描：/private/tmp/nocodb-internal.log（全程窗口四重 grep 零命中）

## 清理

4 个测试 base（SRC/D1/D2/D3，全 `f09p2r4l3-` 前缀）经 f01e2e 删除 200，base 列表残留 0；lane 账号 4 个留存（基建惯例，测试口令仅存 /tmp 脚本不入仓）；camoufox session f09p2r4l3 已 close。
