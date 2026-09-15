# r2-f02-lane3 — F02 Edit field permissions R2 收敛轮(集成测试 + 代码复审)

> 审查对象:4b26d7a23f(F02 实现)+ e85a421d92(R1 修复)。HEAD == e85a421d92(测试开始时,worktree clean)。
> ⚠️ **重要过程声明**:测试进行中(约 06:12,server restart 窗口),工作区被并行进程修改,出现 5 个未提交文件(`Permission.ts` / `permissions.service.ts` / `BaseModelSqlv2.ts` / `Permissions.vue` / `usePermissions.ts`,内含 "R2" 注释与 `validateGrantShape`)。06:12 前的行为测试跑在 R1 bundle(dist 含 4 处 F02 debug log);之后的 V/W 组跑在 R2 未提交版 bundle。下述结论逐条标注归属。

## 结论

**PASS(对 HEAD 两 commit;附 1 条对工作区未提交 R2 修改的回归警告 + 1 条 HEAD 事实已被并行修改消解 + 1 条 E3)**

- issues(仅针对工作区未提交 R2 修改,非 HEAD):
  - `packages/nocodb/src/models/Permission.ts:239-283`(未提交工作区版):`validateGrantShape` 重构时丢失 R1 版 insert 路径的「user grant 必须 subjects 非空」校验(实测 `granted_type=user` 无 subjects → 200 创建成功,deny-all 隐性行为;R1 源码 236-243 行原有该校验)。建议:validateGrantShape 补 `granted_type===USER && !subjects?.length → 400` 分支。
- 事实记录(HEAD 现象,已被并行 R2 修改消解):
  - `packages/nocodb/src/db/BaseModelSqlv2.ts:3058,10575,10613` + `packages/nocodb/src/services/permissions.service.ts:83`(HEAD):4 处 `[F02-Q/R/P/Z]` debug console.log 残留,与 e85a421d92 commit message「Debug probes removed」矛盾,且每次写请求打 2+ 行 log。当前工作区源码已删(dist 0 命中),R2 提交时确认带入即可。
- E3(外部限制/上游遗留,不计 error):
  - `packages/nocodb/src/db/BaseModelSqlv2.ts:4173`(bulkUpsert → afterUpdate):v1 bulk upsert 的 **update 分支** 必 500(`Cannot read properties of undefined (reading 'Id')`,afterUpdate prevData 对齐问题)。owner/editor、full/partial payload 一致复现 → 与 F02 无关;blame 显示调用点为上游 commit 4ee772cf42f(2026-04-20,DarkPhoenix2704),非 fork 引入。insert-only 分支 201 正常。F02 的 403 拦截发生在 checkPermission 层,语义不受影响。建议:随上游跟进或 fork 侧单独修复(bulkUpsert 把 datas[i] 与 existingRecords[i]/updatedDataList[i] 按 Id 对齐后再调 afterUpdate)。
- 观察项(非 error,供裁决参考):
  - `duplicate base` 副本 **不带 permissions**(副本 base permissions=[]):与 F08「shared-base duplicate 落公共」的 fork 语义一致(fail-open 默认),需 orchestrator 确认是否符合预期。
  - `datas.service.ts dataInsertByViewId`(`@Post('/data/:viewId/')`)无可达 HTTP 路由(遗留入口,404);R1 对它的 `isPublicForm` 标记改动实际不可经 HTTP 触发,shared form 提交真实入口是 public shared-view(已测 PASS)。
  - `enforce_for_automation` 列存在但 checkPermission 未消费——F02 范围裁剪(f02-research §6 已裁定),F04/F09 automation 语义时需回头补。
  - `Permission.list` 每 grant 行一次 subjects 查询(N+1)+ 每次调用全量重查(无 request 内复用判断,list 直接覆盖 `context.permissions`)。grant 量级小,实测影响见性能段;量级上去后建议按 base 一次查询 + 内存分组。

## R1 修复验证(全 PASS)

| # | 测试 | 结果 | 证据 |
|---|---|---|---|
| A1 | **v1 单条插入受限字段(editor)→ 403(R1 前是 200 旁路,关键)** | PASS | `Forbidden - You don't have permission to edit the field Secret`;403 未落库(查询 0 行) |
| A1b | v1 插入不含受限字段 → 200 | PASS | Id=4 |
| A2/A2b | v2 单条 insert 受限 403 / 不受限 200 | PASS | 同上 |
| A3 | 重复 grant(API)→ 400 | PASS | `A permission grant already exists for this entity and permission` |
| E1 | **multi-grant any-deny**(SQL 直插 role=editor allow 行 + 既有 nobody → editor 写)→ 403 | PASS | 任一拒绝即拒,插入顺序无关 |
| PF1 | 公共表单匿名提交带 Secret(enforce_for_form=true 默认)→ 403 | PASS | nestedInsert + isPublicForm 钩生效 |
| PF2 | 公共表单匿名提交不带 Secret → 200 落库 | PASS | Id=13 |
| I1 | enforce_for_form=false 后匿名带 Secret → 200(豁免) | PASS | Id=14,Secret=allowed-now |
| I2 | 非 form 上下文 editor API insert 仍 403(enforce_for_form=false 不豁免登录写) | PASS | 语义正确 |
| G1 | **link-only body**(payload 仅系统列+LTAR)→ FIELD 检查空数组跳过,200 | PASS | Id=11(nestedInsert 钩对空 entityId 数组安全) |
| G2/G3 | 标量+嵌套 link insert / 嵌套 PATCH unlink → 200 | PASS | Id=12 / Id=5 |
| G4 | editor 建 grant → 403(permissionCreate ACL creator+) | PASS | ERR_FORBIDDEN permissionCreate |

## 写入路径覆盖面终审(nobody-grant 受限字段,editor 逐路径)

| 路径 | 受限字段 | 不受限 | 备注 |
|---|---|---|---|
| v2 单条 insert(POST /records) | 403 | 200 | |
| v2 数组 insert | 403(整批拒绝,无部分落库) | 200 | |
| v2 PATCH(含 Id) | 403 | 200 | |
| v1 单条 insert | 403(R1 修复核心) | 200 | |
| v1 bulk insert | 403 | 200 | |
| v1 bulk update | 403 | — | |
| v1 bulkUpdateAll(/all) | 403 | 200 | |
| v1 bulk upsert | 403(checkPermission 先拦) | **500(E3 上游 bug,见上)** | insert-only 分支 201 正常 |
| link addChild(POST links/:col/records/:rowId) | 403(LTAR 列 grant) | 201(owner) | C1/C6 |
| link removeChild(DELETE 同路径) | 403 | 200 | C3/C7 |
| link addLinks 多值 / copyPaste(POST links/:col/records) | 403 | — | F3;C2 400 为我方 payload 格式错误后经 F3 覆盖 |
| reorderLink(internal ops nestedDataReorder) | 403 | 422(hm 不支持排序的业务校验,owner 已过权限关) | F1/F2 |
| 嵌套关联写(insert 带 LTAR payload) | 403(LTAR grant 触发)→ 删 LTAR grant 后 200 | 200 | D1-D4 + G1-G3 |
| move(POST records/:rowId/move) | 不涉字段编辑 → 201 | — | B10 |

## skip 通道

- **F07 快照**:owner 建 nobody-grant 表快照 → status=completed;副本 GridA 14 行、Secret 数据完整(row2=sec2 / row1-ed=owner-set / row3=sec3 / own=own-sec / anon-formfree=allowed-now)。PASS。
- **duplicate base**:副本 14 行 Secret 完整。PASS(permissions 不随复制,见观察项)。
- **import 类**:dataImportFile/dataImportPreview operation 存在于 UiPost.operations,经 internal API 触发需要完整 import 载荷,本轮未触发(E3,e2e 22/22 由实现方覆盖该通道;import.service 原生已传 skipPermissionCheck)。
- undo:editor `?undo=true` insert 不含受限字段 200;含受限字段 403(undo 不构成旁路);owner 200。PASS。

## 回归

- 无 grant 表(GridB)editor 全 CRUD(insert/update/list/delete)→ 200。PASS。
- owner 直通:受限字段 insert/PATCH/undo 200。PASS。
- 分页:records?limit=5&page=2 → 200。审计:nc_audit_v2 该 base 52 条 DATA_UPDATE 记录(recordAuditList op 200,直接查库证实记录在写)。PASS。
- F05 variables list [] / F07 snapshots list / F08 base meta / F10 dashboards list → 全 200。F01 无独立 unique 场景,由无 grant CRUD + 快照/复制路径间接覆盖。
- tsc `--noEmit` exit 0;jest `(Integration|Source|Fork)` 桶 2 suites / **26 tests 全过**。

## 性能

PATCH ×5 均值:editor 写无 grant 字段(同表存在 grant)85ms;owner 同表 73-94ms;owner 在零 grant 的 duplicate base 67ms。有/无 grant 差 ~10-20ms(一次 indexed meta list + subjects 查询),常数级,达标。

## 覆盖面声明(未测项)

- 前端 UI(lock 图标/Form 隐藏/配置弹窗)未起前端 dev 实测;本轮验证的是 usePermissions/useViewData/ColumnMenu diff 的静态正确性。
- team/agent subject、enforce_for_automation 语义:裁剪范围外。
- F08 叠加(private base + FIELD grant)未组合测(归 F08 回归)。
