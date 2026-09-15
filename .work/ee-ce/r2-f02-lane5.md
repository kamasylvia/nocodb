# F02 R2 lane5 — 安全终审报告

> 审查对象：4b26d7a23f（F02 实现）+ e85a421d92（R1 修复）。方法：静态审（checkPermission 全挂点 / skip 通道调用方 / isPublicForm 赋值面 / ACL / 校验链）+ dev server API 实测（nocodb-dev，测试号 f02r2l5-*，base p1ln9rz5oc4tzk5 / table m17djitzzil6geq / Secret 列 csgdlq2v8hrc78c）。测试数据已清理（permissions 表还原为空）。

## 结论

issues（3 项，均修复引入面/残留，非新绕过）：

1. `packages/nocodb/src/db/BaseModelSqlv2.ts:3058`、`:10575`、`:10613`、`packages/nocodb/src/services/permissions.service.ts:83` — 问题：4 处 `[F02-Q]/[F02-R]/[F02-P]/[F02-Z]` console.log 调试探针残留在 R1 commit 内（commit message 自称 "Debug probes removed"，不实）；其中 permissions.service.ts:83 每次 create grant 把整 base 权限清单（id/entity/entity_id/permission）全量 JSON 打进服务日志，BaseModelSqlv2.ts:10575 每次数据写请求打印当前用户 projectRole/isOwner — 权限元数据入日志 + 日志噪音，违反 TASK 验收「无 console 残留」同族项 — 建议：4 行全删（含配对的 eslint-disable no-console 注释）。
2. `packages/nocodb/src/models/Permission.ts:274-349`（update）+ `packages/nocodb/src/services/permissions.service.ts:110-132` — 问题：R1 校验收紧只覆盖 insert；update 对 granted_role 无枚举/minimumRole 校验，create 层拒绝的 `granted_role:"viewer"`（低于 RECORD_FIELD_EDIT minimumRole=EDITOR）与任意串 `"notarole"` 经 PATCH 均 200 落库（实测）。实际影响有限：'viewer' 使 grant 变宽但 viewer/commenter 无数据写 ACL（可写面≈0）；'notarole' 在 evaluatePermission 中 rolePower 比较 undefined → deny-all（保守方向，破坏 grant 可用性）— 建议：update 复用 insert 的 granted_role 验证块（targetType===ROLE 时同样校验枚举 + minimumRole）。
3. `packages/nocodb/src/services/datas.service.ts:1218` — 问题：认证路由 POST /data/:viewId/（GlobalGuard + @Acl('dataInsert')）被无条件标 `(param.cookie).isPublicForm = true`。该标志仅 nestedInsert 挂点读取，而此路径走 insert.ts single，其 checkPermission 调用（insert.ts:69-77）未传 options → 标志当前无效（实测 T8b 403，无绕过），属死代码 + 语义污染：一旦 insert.ts 挂点未来接入 options.isFormContext，登录 editor 即可经此认证路由跳过 enforce_for_form=false 的 grant（静态推演：checkPermission user 循环对 isFormContext 跳过 eff=false grant）— 建议：删除该标注行（req 传递本身保留，它是 R1-c 修复的有效部分）；或仅对真实 shared/public 语境标注。

## R1 修复复检（逐项，全部生效）

| R1 项 | 复检方式 | 结果 |
|---|---|---|
| a. nestedInsert 补钩 | editor v1 `POST /api/v1/db/data/noco/:base/:tbl` 带 Secret → 403，psql 确认 0 行落库；匿名 `POST /api/v2/public/shared-view/:uuid/rows`（eff=true 默认）带 Secret → 403；grant 改 eff=false 后匿名提交 → 200 且 Secret 值直接落库（opt-out 语义=放行整行含受限值，非剥离——EE 语义一致性可接受，已记录） | ✓ |
| b. multi-grant any-deny + 去重 | API 建 role=creator grant 后 psql 直插第二行 role=editor（绕过 service 去重）→ editor 写 403（deny grant 存在即拒，list 顺序无关；R1 前仅评 grants[0] 会被首条 allow 放行）；API duplicate create → 400 "A permission grant already exists" | ✓ |
| c. form 提交传 req | editor 登录态经 datas.service `POST /data/:tableId/`（dataInsertByViewId → insert.ts single）带 Secret → 403（R1 前传 null request fail-open） | ✓ |
| 校验收紧 | create：granted_role=viewer / 非法枚举 / 无 subjects user grant → 400（建 grant 复测过 viewer 拒绝路径经 T9 反向确认：同输入 PATCH 200 = 缺口在 update，见 issue 2）；nobody 转换显式/隐式均清 granted_role（实测两者返回 granted_role=None） | 部分（update 缺） |

## 绕过面枚举（editor + nobody/creator-deny grant 下实测，除标注外全 403）

| 面 | 端点/路径 | 结论 |
|---|---|---|
| v2 单行插入 | POST /api/v2/tables/:t/records | 403 ✓ |
| v2 单行更新（title 键） | PATCH records {"Id":1,"Secret":…} | 403 ✓（mapAliasToColumn 归一后检查，title↔column_name 混键无差异；column_name 键同样 403） |
| v1 nestedInsert | POST /api/v1/db/data/noco/:b/:t | 403 ✓ 0 行落库 |
| v1 行更新 | PATCH /api/v1/db/data/noco/:b/:t/:id | 403 ✓ |
| v1 view 插入（登录） | POST /data/:t/ | 403 ✓（R1-c） |
| bulkInsert | POST /api/v1/db/data/bulk/… | 403 ✓ |
| bulkInsert undo | 同上 ?undo=true | 403 ✓（undo 参数不影响检查） |
| bulkUpdate | PATCH /api/v2/tables/:t/records（数组） | 403 ✓ |
| bulkUpdateAll | PATCH records?where=(Id,eq,1) | 403 ✓ |
| bulkUpsert | POST /api/v1/db/data/bulk/…/upsert | 403 ✓ |
| link v2 add/remove | POST/DELETE /api/v2/tables/:t/links/:col/records/:rowId | 403 ✓（grant 建在 link 列 id 上） |
| link v1 relationDataAdd | POST /api/v1/db/data/…/hm/:col/:ref | 403 ✓（→addChild） |
| link 静态余面 | removeChild/addLinks/removeLinks/reorderLink（BaseModelSqlv2.ts:6852/8734/8751/8769）、updateLTARCols:4737 | 挂点齐，user 均 cookie?.user ✓ |
| isFormContext 伪造 | 匿名 body {"isPublicForm":true} / ?isPublicForm=true | 403 保持 ✓；赋值点仅 datas.service.ts:1218 与 public-datas.service.ts:827 两处服务端（grep 全仓确认），请求层不读 body/query |
| move row | body 仅 order/pk；order 为 system 列，fieldPermissionEntityIds 豁免 system/pk/FK | 不触受限字段 ✓ |
| webhook 触发写 | webhook 仅通知无数据写路径；内部重写列（select option rename）走 skipValidationAndHooks=true（columns.service.ts:2555/2777/2887，creator 列操作） | 无 editor 可达面 ✓ |
| skip 通道 | skipPermissionCheck=true 仅 import.service.ts:2494/2536/2603；raw 模式同；bulk controller 白名单构造 param（body/cookie/baseName/tableName/undo），skipPermissionCheck 不自 HTTP | HTTP 不可控 ✓ |
| MCP 预载 | req.permissions 仅 mcp.controller loadPermissions 装载，同 base 上下文 | 无跨 base 注入 ✓ |

## fail-open 完整性

- 无 grant：v2 插入 200、匿名 form 提交 200（基线 + 收尾各测一次）。
- grant create → delete 后立即 editor 写 200、list 返 []：Permission.list 已 cache-free（直查 + context.permissions 请求级标记），无 NocoCache stale/evict 伪影；'NONE' 哨兵在当前实现中不存在（R1 重构消除）。
- 匿名非 form 上下文（insert.ts 路径匿名请求被 GlobalGuard 挡 401）不存在匿名 fail-open 残留。

## 提权面

- editor 对 permissions 管理面 GET/POST/PATCH/DELETE 全 403（permission* ops 在 acl.ts base scope creator 段，实测 "permissionCreate … roles: Editor" 拒绝）。
- 跨 base 归属：service.update/delete 校验 `existing.base_id !== baseId` → 400；create 时 entity_id 指向他表/他 base 列 → 行落本 base 但写路径 entityIds 恒来自本 base 列集合 → inert，无跨 base 激活面。
- API token：token 认证产出的 req.user 携带 project role，走同一 checkPermission 判定，无独立绕过通道（xc-token 与 xc-auth 同链路）。

## 实测证据摘要

- 测试序列 T1-T15/TF/TN 共 24 个断言：403 断言 16 个（v2/v1/视图/bulk×4/link×4/匿名×2/伪造×2/管理面×5 中 4 个 403 + 1 个 GET 403）、200 断言 5 个（fail-open 基线/收尾、匿名 eff=false 放行、匿名无受限字段 ×2）、400 断言 1 个（去重）、落库核验 2 次（403 后 0 行 / opt-out 值落库）。
- R1 修复的 3 个安全面（nestedInsert、multi-grant any-deny、form req）全部复测通过；修复未引入可利用的新绕过（issue 3 为无效标志而非活绕过）。
- E3：无（后端 rspack 重建窗口一次，等待 100s 后恢复，非外部限制）。
