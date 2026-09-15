# R7 F02 Edit field permissions — lane3 报告（功能全量集成测试 + 整个 diff 代码复审）

- 审查对象：4b26d7a23f（实现）+ e85a421d92/3b9dcbdbc6/a8fc2c2966/b95fbf7f74/10e8d92729（R1–R5）+ 0711660b8c（R6 修复），HEAD = ca6c81f5a6
- 环境：dev 后端 :8080（含 R6 修复）、nocodb-dev 库（qnap.elf-balance.ts.net:5432）、owner/editor/creator 三角色账号（r7l3own/r7l3edt/r7l3crt@ce-ee.local，owner 经 psql 提权 super，editor/creator 经 nc_base_users_v2 直插）
- 隔离：仅读仓根 AGENTS.md、TASK.md、f02-research.md、源码、git diff；未读其他 lane 报告与归档

## 结论

**PASS**（0 个 F02 error；2 条非 F02 观察：1 条上游缺陷 E3，1 条低危加固建议；UI 段部分覆盖见 T7）

## R6 修复验证（重点）— T1

布局（R6 原始劫持几何，decoy 前置）：T1 (`mh47t3fxcs9rsue`) 列序 = … → colY(`ci9dgmukpxp070q`, title=**Q2**, column_name=decoy) → colX(`cfmo0ju3fbp4fo1`, title=QX, column_name=**Q2**)。colX 挂 nobody grant（`permskm9apnlohae08`）。

| 用例 | 载荷键 | 期望 | 实测 |
|---|---|---|---|
| editor PATCH 歧义键 `Q2`（= colY.title + colX.column_name） | `{"Id":1,"Q2":"edt-hijack"}` | **403**（旧 build 200 劫持） | **403** `You don't have permission to edit the field QX` |
| owner 同载荷 | 同上 | 200 且写目标确为 colX | **200**；行读回 `Q2/QX` 均显示 `own-val` → 写入真实落在 colX（403 非空拦） |
| editor 无歧义 title 键 `QX` | 403 | 403 ✓ |
| editor id 键 `cfmo0ju3fbp4fo1` | 403 | 403 ✓ |
| editor 写未受限 colY（column_name `decoy`） | 200 | 200 ✓（无过度拦截） |
| editor 仅写 `Name`（不触碰 colX） | 200 | 200 ✓ |

代码侧核实：`fieldPermissionEntityIds`（BaseModelSqlv2.ts:10533-10558）改为双层循环 + Set 收集**全部**命中，三键（column_name/title/id）匹配，system/pk/FK/systemColumn 过滤保持；歧义键过度拦截 = 安全方向，与序无关。R6 附带清理的杂散文件 `PATCH`/`-X` 已从 HEAD 移除，工作区干净。

## T2 全矩阵（grants × 角色 × 写路径，对照表 T2 无碰撞）

T2 (`m9y0bnl8w3w5exw`) 四列各一 grant：nc1=nobody、rc1=role(creator)、ec1=role(editor)、uc1=user(subjects=[editor])。角色：editor(r7l3edt) / creator(r7l3crt) / owner(r7l3own)。8 条写路径：

patch=`PATCH /api/v2/tables/:t/records`；insert=`POST …/records`；bulkins=`POST /api/v1/db/data/bulk/noco/:b/:t`；bulkupd=`PATCH /api/v1/db/data/bulk/noco/:b/:t`；updall=`PATCH …/bulk/noco/:b/:t/all`；upsert=`POST …/bulk/noco/:b/:t/upsert`；v1ins=`POST /api/v1/db/data/noco/:b/:t`；v1upd=`PATCH /api/v1/db/data/noco/:b/:t/:rowId`

```
nobody        ET: 全路径 403   CT: 全路径 403   OT: 全路径 200   ✓
role-creator  ET: 全路径 403   CT: 全路径 200   OT: 全路径 200   ✓
role-editor   ET: 全路径 200   CT: 全路径 200   OT: 全路径 200   ✓
user(editor)  ET: 全路径 200   CT: 全路径 403   OT: 全路径 200   ✓
```

48/48 分界全对（原始输出 matrix2.out）。注：upsert 列在允许侧为 500，见「观察 1」——拦截侧 403 正确，允许侧 500 为上游缺陷、非 F02。

## T3 fail-open

| 用例 | 结果 |
|---|---|
| 无任何 grant 的 T3（`mydtjqa6y0dmvdl`）：editor insert / PATCH | 200 / 200 ✓ |
| T2 nc1 grant 在位：editor PATCH | 403 ✓ |
| DELETE grant（200）后下一个请求 | 200 放行 ✓（无缓存滞后） |
| 重建 nobody grant（200）后 editor PATCH | 403 ✓（恢复即时生效） |

## T4 校验对称性 + ACL（16/16 全 400/403）

create：role 缺 granted_role=400；user 缺 subjects=400；granted_role 非法枚举=400；viewer 低于 minimumRole=400；nobody+subjects=400（R5 对称）；重复 grant=400（R1 唯一性）；非法 entity=400；table-entity=400（F02 范围裁剪）。
update：nobody+subjects=400；切 role 缺 granted_role=400；切 user 缺 subjects=400；granted_role 非法枚举=400；viewer 低于 minimumRole=400；granted_role 显式 null=400（R4 final-stored-value 语义）。
ACL：editor POST /permissions=403、editor DELETE=403（create/update/delete creator+，permissionList editor+，acl.ts:279/559 位置核实）。

## T5 公共表单（enforce_for_form）

共享 form view uuid `40d62b29-9fd6-460e-bfd2-46461ddd0279`（T2）。载荷格式 `{"data":{列title:值}}`（public-datas.service 按 title 映射；本 lane 首测误用顶层/列名键，修正后测得）：

- enforce_for_form=**true**（默认）：匿名提交受限字段 → **403** `You don't have permission to edit the field NC` ✓
- enforce_for_form=**false**：匿名提交受限字段 → **200**，psql 验证行 50 `nc1='form-fine'` 实际落库 ✓
- 未受限字段匿名提交恒 200 ✓

机制核实：public-datas.service 注入匿名 service user（usranonymous，无角色）→ checkPermission 对任何 grant（除非 enforce_for_form=false）一律 deny；`isPublicForm` 标志仅在 nestedInsert 挂点生效，认证用户走 view 提交端点（datas.service:1213 传 cookie、刻意不标 form 上下文）语义正确。

## T6 回归

| 项 | 结果 |
|---|---|
| F05 变量 | list 200；create（key/value）200 ✓（首测 name/value 400 为参数名错误，非回归） |
| F07 快照 | create 200 → status processing→**completed**；snapshot_base 可读 200 ✓ |
| F08 私有 base | PATCH is_private:true →200，读回 true；删除 200 ✓ |
| F10 dashboard | list 200；create 200 ✓ |
| tsc | `npx tsc --noEmit` **0 错误** |
| jest | **26/26 pass**（2 suites） |

## T7 UI 段（camoufox；部分覆盖）

- camoufox MCP 拒 localhost（私网目标）→ 回退 camoufox-cli（全局三级规则）。
- 实测通过：真实浏览器登录 owner → base Settings → `proj-view-tab__permissions` tab 存在且点击后 **Data Permissions 内容真实渲染**（View.vue F02 gate 解锁生效）；同页 Variables/Snapshots tab 在位（F05/F07 UI 回归）。
- 未覆盖：grid ColumnMenu 菜单项与 `DlgFieldPermissions` 弹窗的实际点击——本版本 grid 为 canvas 渲染（942x628 单 canvas），合成事件无法触发 header hover/菜单；弹窗逻辑已逐行复审且其全部 API 交互（list/create/patch/delete + enforce_for_form PATCH）在 T1–T5 经 API 全覆盖。记为 UI 段缺口（E3：工具能力限制，非产品缺陷）。

## 代码复审（整个 diff）

已读全部 F02 触碰面：Permission.ts（list/get/insert/update/delete/deleteByBaseId/isAllowed/findGrants/validateGrantShape）、BaseModelSqlv2.ts（fieldPermissionEntityIds/checkPermission/6 挂点）、insert.ts（2 挂点）、IBaseModelSqlV2.ts、permissions.controller/service、acl.ts、noco.module.ts、Base.ts（base 删除清理 ×2）、datas.service、public-datas.service、前端 usePermissions/useEeConfig/useViewData/Permissions.vue/Modal Content/Tooltip/View.vue/Details.vue/ColumnMenu/Form.vue/i18n。

核对结论：
- **checkPermission 任一拒绝即 403、multi-grant 顺序无关**（denied 标志短路循环）✓；owner 直通（getProjectRole→base_roles，extract-ids 全路由填充）✓；fail-open 契约（无 grant/空列表→放行）✓；skipPermissionCheck 在 bulkInsert/路径尊重（insert.ts:345、bulkUpdate raw、bulkUpsert raw）✓
- **update() resolved-type 三守卫**（nobody+subjects / role 缺 role / user 缺 subjects）先于写库，nobody 切换清理 granted_role + subjects 重建后兜底清理 ✓
- **validateGrantShape 共享**：create(requireSubjectsForUser) 与 update 对称；enum/minimumRole/subjects 形状/nobody+subjects 全覆盖（T4 实证）✓
- 探针/console.log/debugger/TODO：diff 新增行 **0** ✓；错误消息只暴露列 title（用户可见标签），无内部 id/栈泄漏 ✓
- 前端 usePermissions：per-base 懒加载 + force 刷新（R2）+ base 切换失效；isAllowed/getPermissionSummary 与后端同源（SDK evaluatePermission 经 utils/tableFieldPermission）✓；grant 唯一性由 service create 去重保证（grants[0] 取法成立）
- 性能：每次数据写在 base 含 grant 或不含时均为一次索引 meta 读（list 1+N 子查询）——可接受，无回归级放大（见观察 3）

### 观察（非 F02 error）

1. **E3/上游缺陷**：`POST /api/v1/db/data/bulk/noco/:b/:t/upsert` 允许侧恒 500（`Cannot read properties of undefined (reading 'Id')` @ BaseModelSqlv2.ts:6013 afterUpdate ← 4171）。根因：PK-based upsert 分支（:3767 else 起）**不给 existingRecords 赋值**（仅 merge 分支 :3759 赋值），单行更新时 `afterUpdate(existingRecords[0]=undefined,…)` 崩溃。crash 代码为上游 mertmit/DarkPhoenix2704（2026-04），`git show 4b26d7a23f^` 同构，F02 未触碰；拦截侧行为（403）正确。建议：另开 upstream-fix 或 fork 修复单（在 PK 分支回填 existingRecords 或 afterUpdate 判空）。
2. **低危加固建议**：permissions.service.create 校验 entity_id 列存在但未校验该列属于 `:baseId`（Column.get 非按 base 过滤）→ creator 可在本 base 创建指向他 base 列的惰性 grant 行。无提权效果（list 按 base 隔离，永不消费），仅数据卫生。建议：create 时比对 `table.base_id === baseId`。
3. 性能注记：所有写路径每请求一次 `Permission.list`（1+N 查询）——索引小读，当前规模可接受；后续 F03 复用时再评估 per-base 缓存。

## 证据文件

- 矩阵原始输出：`.work/ee-ce/r7-lane3-tmp/matrix2.out`
- 测试脚本/状态：`.work/ee-ce/r7-lane3-tmp/`（api.sh、matrix2.sh、token/ids 文件）
- 关键 id：T1=`mh47t3fxcs9rsue`、T2=`m9y0bnl8w3w5exw`、T3=`mydtjqa6y0dmvdl`、base=`pjv0b7jmrwnmo6d`
