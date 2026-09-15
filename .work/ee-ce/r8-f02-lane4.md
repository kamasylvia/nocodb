# R8 F02 lane4 终局收敛报告（功能全量集成测试 + 全 diff 复审 + UI 段）

**结论：PASS（0 error）**

非 error 观察项 2 条（见「观察项」节，均有诊断证据，不触发修复闸门）：
- O1 bulkUpsert 单行已存在 PK → 500：上游遗留（blame 4ee772cf42f，2026-04-20，F02 未触碰该调用点），与权限无关
- O2 canvas grid 头部无 lock 图标：canvas 渲染层以 hover tooltip + 灰边框替代 DOM lock，功能拦截完整

---

## 1. R7 修复验证（重点，ca6c81f5a6）

visible watch `{ immediate: true }` 修复验证，双路径均过：

| 路径 | 首开回显 | Reset 按钮 | Save 行为 |
|---|---|---|---|
| Details tab → Permissions tab → Secret 行 Edit | **Nobody 选中**（`nc-field-permission-nobody` 带 SELECTED 边框类，spinning=false 非中间态） | `nc-field-permission-reset` 在位 | Save 后 nc_permissions 该 base 行数 **4→4**、Secret grant 仍 1 行（PATCH 非 POST，无重复）；弹窗正常关闭 |
| ColumnMenu → 右键 Secret 列头 → Edit field permissions | **Nobody 选中** | 在位 | 同上（同一组件实例） |

证据截图：
- `.work/ee-ce/shots/r8-lane4-owner-dlg-nobody-firstopen.png`（Details tab 路径，Nobody 高亮 + Reset field permissions）
- `.work/ee-ce/shots/r8-lane4-owner-dlg-columnmenu-path.png`（ColumnMenu 路径，同回显）

## 2. grant 矩阵（全量：5 grant 态 × 3 角色 × 7 写路径 = 105 格）

表 `Sheet1`（base php5yq3wc0v4nsj / ml99hivrlsxz16v），每列一种 grant：Secret=nobody、ColRoleE=role(editor)、ColRoleC=role(creator)、ColUser=user(subjects=[creator uid])、ColNone=无 grant。路径：v2 PATCH 单条 / v2 POST insert / v1 bulkInsert / v1 bulkUpdate / v1 bulkUpdateAll（/all）/ v1 bulkUpsert（新 PK insert 侧）/ v1 单条 insert。

结果（HTTP 状态）：**105 格全部符合预期分界，零偏差**

| grant | owner | editor | creator |
|---|---|---|---|
| nobody | 全 200/201 | 全 403（7/7 路径） | 全 403 |
| role(editor) | 全 200 | 全 200 | 全 200 |
| role(creator) | 全 200 | 全 403 | 全 200 |
| user(creator) | 全 200 | 全 403 | 全 200 |
| 无 grant | 全 200 | 全 200 | 全 200 |

关键分界实证：owner 直通（即便 nobody）；role power 比较（editor < creator 被拦）；user subject 匹配（非 subject 的 editor 被拦）；multi 路径挂点齐全（bulkUpdateAll/updateLTARCols 汇聚路径经 /all 与 upsert 侧面覆盖均 403）。

## 3. fail-open 与 revoke 生效

- 全部 grant 删除前库内 31 行（历史轮遗留，其他 base）不影响本 base 判定：本 base 无 grant 列全角色 200（fail-open）✓
- DELETE nobody grant（permgwe9pk5kj8r6lz → 200）→ editor 下一请求 PATCH Secret = **200**（下一请求即放行，无缓存残留）✓

## 4. 校验对称（create/update 400 矩阵）

CREATE（无 grant 列 ColNone 上验证，避免 duplicate 检查前置遮蔽）：

| 用例 | 结果 |
|---|---|
| nobody+subjects | 400 `subjects are not allowed on nobody grants` |
| role 缺 granted_role | 400 `granted_role is required for role grants` |
| user 缺 subjects | 400 `subjects are required for user grants` |
| granted_role=bogus | 400 `Invalid granted_role bogus` |
| granted_role=viewer（低于 minimumRole=EDITOR） | 400 `granted_role viewer is below the minimum role for RECORD_FIELD_EDIT` |
| 合法 role(creator) 对照 | 200 → DELETE 200 清理 |

另：bad entity 400 / table entity 400（F03 预留拒） / field+TABLE_RECORD_ADD 400 / 列不存在 400 / **editor create 403（ACL permissionCreate）+ editor list 200（permissionList）** / 重复 grant 400。

UPDATE（roleE grant permbkv15f1xfux4oy 上）：nobody+subjects 400 / `granted_role:null` 400 / `""` 400 / bogus 400 / viewer 400 / granted_type=superuser 400；**全部 400 后 psql 复核行未变（role/editor 原样）**。user grant（perm2mw79bkw51cajf）：空 subjects 400 / team subject 400 / 切 nobody 200（granted_role=null、subjects=[] 清理）→ 切回 user 200（subjects 重建正确）。

注：`GET /permissions/:id` 无路由（controller 只有 list/POST/PATCH/DELETE），404 = 路由不存在，非数据缺陷；Permission.get 仅内部使用且 service update/delete 有 base_id 归属校验（跨 base PATCH 拒）。

## 5. 公共表单 enforce_for_form（匿名提交，data 包裹 payload）

| enforce_for_form | 匿名提交含 Secret | 结果 |
|---|---|---|
| true（默认） | `{"data":{"Title":...,"Secret":...}}` | **403** `Forbidden - You don't have permission to edit the field Secret` |
| false（PATCH 后） | 同 payload | **200**，Secret="form-pass" 落库（DB 复核 row 92） |
| 恢复 true | 同 payload | **403** 再次拦截 |

## 6. 回归 + 静态检查

- F05 变量：list 200 / create `R8_VAR` 200（首测 400 为本路 payload 键误用 name/key，非缺陷）
- F07 快照：create 200 → status **completed**（列表复核）
- F08 私有 base：PATCH is_private true/false 双向 200
- F10 dashboard：create 200 + list 200
- tsc：`cd packages/nocodb && npx tsc --noEmit` exit 0
- jest：**26/26 passed**（2 suites：baseVariableValidators / uniqueConstraintHelpers Fork 桶）

## 7. UI 段（camoufox-cli，:3000）

1. owner：base 级 Permissions tab 可见（gate 已解）；Details → Permissions tab 6 字段行全渲染，摘要正确（Secret=Nobody、ColRoleC=Creators & up、ColUser=Specific users、其余 Default — Editors & up）
2. R7 首开回显双路径验证（见 §1，截图 2 张）
3. editor：Secret 单元格 dblclick **无编辑器打开**（isEditRestricted → null 返回）；Title dblclick 编辑器打开 → 改值 Enter → **DB 复核 Title="ui-title-by-editor" 落库**（无 grant 字段 UI 写入正常）
4. editor 右键列头无 "Edit field permissions" 菜单项（fieldAlter gate，owner 同操作可出菜单——事件路径同一，对比有效）
5. console error / 5xx：editor 会话探针（console.error + fetch>=500 + XHR>=500）计数 **0/0**；owner 弹窗操作段无异常表现
6. editor 网格截图：`.work/ee-ce/shots/r8-lane4-editor-grid.png`；Secret 列头放大：`r8-lane4-editor-secret-header-zoom.png`（见 O2）

## 8. 代码复审（六 commit + 1 fix 全 diff，24 文件 +1630/-56）

**通过项（逐点核验）：**
- `fieldPermissionEntityIds`（BaseModelSqlv2.ts:10530 区）：title/column_name/id 三键全匹配 + Set 去重；system/pk/ForeignKey/isSystemColumn 四重豁免；R6 全收集语义（collision 时 over-block 安全向）实现正确
- `checkPermission`：owner 直通（getProjectRole→OWNER return）；fail-open（空 grant 列表 / 无 grants for entity 双层 return）；multi-grant any-deny-wins（循环 break，顺序无关）；匿名仅 form 上下文放行（`enforce_for_form===false` 全体才 continue）；错误消息用字段 title、无 id/栈泄漏；per-request context 取 `req.context`（R1 修复的实例缓存问题有对应代码）
- 挂点完备性：updateByPk(2811)/nestedInsert(3050, isPublicForm)/bulkUpsert(3653, raw skip)/bulkUpdate(4493, raw skip)/updateLTARCols(4721, title 键经三键匹配)/bulkUpdateAll(4784, skipValidationAndHooks skip)/insert.ts single(65)+nested(341, skipPermissionCheck)。trusted 通道核对：import.service 3 处 skipPermissionCheck:true、bulk-data-alias 透传、duplicate/import 走 bulk raw/skip 路径——F07 快照复制不受自拦（回归实测快照 completed 佐证）
- `Permission.update` 三守卫顺序：validateGrantShape → nobody+subjects → grantedRoleToStore 空值兜底（显式 null/'' 被 `?? ''` 归一后由 role-grant 必填检查拦）→ user subjects 兜底（existing.subjects）；全在写前抛 400（实测 state intact）；nobody 收尾清 subjects（含 rebuild 后再删的冗余但正确）
- `validateGrantShape` 共享：enum 校验 / minimumRole（PermissionMeta[RECORD_FIELD_EDIT].minimumRole=EDITOR）/ subject 形状 / nobody+subjects；create 侧 requireSubjectsForUser=true、update 侧由后置守卫补——create/update 语义对称（§4 实测）
- ACL：`permissionList` 加 EDITOR include（creator/owner 经 exclude-通配继承，extract-ids.middleware.ts:1299-1303 判定逻辑确认）；Create/Update/Delete 未入 editor → 403 实测
- service.create 门禁：entity 枚举 / 列存在 / synced 拒配 / table entity 拒（F03 预留不收 inert 行）/ FIELD 键限 RECORD_FIELD_EDIT / 重复 grant 400 / team subject 拒
- `Base.delete/softDelete` 均挂 `Permission.deleteByBaseId`（孤儿清理，与 BaseVariable 同款）
- 探针/console.log/debugger 残留：diff 全文 **0**
- i18n：en/zh-Hans `permissionUpdated` 成对新增；其余键全部复用既有 CE 键

**观察项（非 error）：**
- **O1** `bulkUpsert` 对「单行 + 已存在 PK」返回 500（`afterUpdate` 读 `existingRecords[0].Id`，PK 分支 existingRecords 未回填）：`git blame -L 4169,4176` = 4ee772cf42f（DarkPhoenix2704, 2026-04-20，上游基线代码），F02 六 commit 未触碰该调用点；owner/任意角色同触发，与权限判定无关；F02 hook 在该 500 **之前**执行（blocked 用户该路径实测 403 正常）。属上游遗留缺陷（E3 类：非本 fork 引入，有 blame 诊断），矩阵中 upsert 侧改用新 PK 验证 insert 语义、已存在 PK 侧经 bulkUpdate 路径等效覆盖
- **O2** canvas grid 表头无 lock 图标：本仓 grid 为 canvas 渲染（单 canvas，DOM header Cell.vue 不挂），受限列走 `isCellEditable=false` → hover "Edit restricted" tooltip + 灰边框（useCanvasRender.ts:1069-1091）+ dblclick 拦截（useCanvasTable.ts:1904,1975）。功能拦截三层全实测生效，仅视觉提示形态与 DOM grid lock 图标不同，属 canvas 渲染层实现差异，F02 挂点接线完整
- O3（备忘）`Permission.list` 无缓存（R1 注释明示放弃 NocoCache 的理由），每次写请求 1+N subjects 子查询；grant 数小 + 索引在（nc_permissions_entity），当前规模无实际回归，F03 扩面时若 grant 数增长建议重估

## 9. 测试环境与数据

- 后端 :8080（未重启）、前端 :3000、DB qnap.elf-balance.ts.net:5432/**nocodb-dev**（库名显式硬编码，未触碰 nocodb 生产库）
- 测试对象：base `php5yq3wc0v4nsj`（r8lane4-f02）/ table `ml99hivrlsxz16v`；账号 owner/editor/creator@r8lane4.test（owner 经 psql 提权 super）；grant 4 行留在库内供后续轮复核，测试行未清理（dev 库）
- 唯一主动触发的 500 = O1 场景（诊断用），非探针期外无其他 5xx
