# F02 Edit field permissions — R7 lane4 报告（功能全量集成测试 + 全 diff 代码复审 + camoufox UI 段）

**结论：1 issue**

```
packages/nc-gui/components/dlg/Field/Permissions.vue:250-260 (watch visible) + packages/nc-gui/components/permissions/Modal/Content.vue:34-37 (openField 挂载方式):弹窗随 visible=true 同时首挂载时 watch(无 immediate)不触发,loadCurrentGrant/loadMembers 不执行,已有 grant 不回显(选中项回落 Editors & up、Reset 按钮不出现);此时点 Save 会 POST 重复 grant → 400 报错弹窗,误导配置者:建议 watch 加 { immediate: true } 或 onMounted 时 visible 为 true 即执行 loadCurrentGrant()
```

其余全部通过。证据逐项如下。

---

## 1. R6 修复验证(重点)——PASS

构造:base R7L4F02 / 表 Matrix,前置诱饵列 `Q2{column_name=q2col}`(先建),后建碰撞列 `QX{title=QX, column_name=Q2}`,对 QX(col `cma99c4c9wh9ago`)配 nobody grant。

| 断言 | 结果 |
|---|---|
| editor PATCH `{"QX":"hax-title"}`(title 直击受限列) | **403** `Forbidden - You don't have permission to edit the field QX` |
| editor PATCH `{"Q2":"hax-cn"}`(**劫持向量**:键同时命中诱饵 title 与受限列 column_name) | **403**(旧 build find() 单命中诱饵 → 200;修复后收集全部命中,任一受限即拒) |
| owner 同载荷 `{"Q2":...}` | **200**(写入库中 Q2/QX 两列,属上游 mapAliasToColumn 对歧义键的原生行为,与权限层无关) |
| 混合键 `{"Extra":"ok","QX":"no"}` editor | **403**(任一受限即拒) |
| 无碰撞对照:editor PATCH Extra/Name | 200/200 |
| 单键无碰撞(Secret title/`secret` column_name) | 403/403,无过度拦截 |

## 2. 全矩阵 grants × roles × 路由——PASS

表 Mx(Sec 列受限)。8 路由 × 4 grant × 3 角色,结果全部符合预期分界(仅列关键行):

| grant | editor | creator | owner |
|---|---|---|---|
| nobody | 8 路由全 403 | 8 路由全 403 | 8 路由全 200 |
| role(editor) | 全 200 | 全 200 | 全 200 |
| role(creator) | 全 403 | 全 200 | 全 200 |
| user(subjects=[editor id]) | 全 200 | 全 403 | 全 200 |

路由覆盖:v2 PATCH/POST `/api/v2/tables/:tid/records`、v1 insert/update `/api/v1/db/data/noco/:base/:tid[/1]`、bulk insert/update/updateAll(`/all`)/upsert(`/api/v1/db/data/bulk/noco/:base/:tid...`)。actor=owner 全 200(owner 直通)。

⚠️ 观察项(非 F02):`bulkUpsert` **单行更新**载荷(数组恰含 1 条带 Id 行)对所有人(含 owner、无 grant 基线)500,`TypeError: Cannot read properties of undefined (reading 'Id')` @ `afterUpdate`(bulkUpsert 的 isSingleRecordUpdation 分支)。已核实:① 无 grant 基线同样 500;② owner 走 checkPermission owner 直通,未触碰任何 F02 逻辑;③ 该调用点 `afterUpdate(prevData[0], newData[0], cookie, datas[0])` 在 parent commit(4b26d7a23f^)逐字节相同,F02 diff 对 afterUpdate 及其调用点 0 改动;④ 多行更新/纯插入 upsert 均 201。定性:**上游既有 bug,与 F02 无关**,建议另行跟踪。

## 3. fail-open——PASS

- 无 grant 基线:editor 8 路由全 200。
- 每轮 grant DELETE 后下一请求即放行(editor v2PATCH=200),共验证 4 轮。
- 代码侧:`checkPermission` 对 `permissions?.length===0` 早退(`BaseModelSqlv2.ts:10580` 附近),`fieldPermissionEntityIds` 空载荷返回 `[]`;req.permissions 预载(MCP)优先,`req.context ?? this.context` 修掉了实例缓存 context 的串味(R1)。

## 4. 校验对称——PASS

create(creator,全 400):nobody+subjects / role 缺 granted_role / user 缺 subjects / granted_role 非法枚举(superuser) / viewer、commenter 低于 RECORD_FIELD_EDIT minimumRole / 非法 entity / 非法 permission key / table entity 拒收(F03 预留) / 不存在的 column id;合法 nobody → 200。
update(全 400):nobody+subjects / 转 role 缺 role / granted_role 显式 null / 显式空串 / 非法枚举 / viewer 低于 min / 转 user 无 subjects / user+team subject(team 未支持) / 非法 granted_type;合法 nobody→role(creator) 200;转 nobody 后 granted_role 落库为 null(R3 不变量)。
重复 create 同 (entity,entity_id,permission) → 400(唯一性保证前端 grants[0] 取单元素等价于后端多 grant 全评)。
ACL:editor permissionList=200、permissionCreate=403;creator list/create=200(acl.ts:279 scope + :559 editor include,Create/Update/Delete 未进任何 include → creator+,与 F05 同款模式)。

## 5. 公共表单——PASS

共享表单 FormR7(vwllq4oyen8u6sde,uuid b50f39fd-…),匿名 POST `/api/v2/public/shared-view/:uuid/rows`,载荷需 `{"data":{...}}`(controller 取 `req.body.data`,首两轮 404/null 行系本路载荷形状误用,非产品问题):

| 状态 | 提交 | 结果 |
|---|---|---|
| enforce_for_form=true | 含 Sec | **403** `…edit the field Sec` |
| enforce_for_form=true | 仅 Name | **200**(未受限字段可正常提交) |
| enforce_for_form=false | 含 Sec | **200**,Sec 值实际落库(anonC/secretC 查询证实) |

注:public-datas.service 为匿名提交注入 `NOCO_SERVICE_USERS[ANONYMOUS_USER]`(`req.user` 恒真),故 checkPermission 的 `!user` 匿名分支在该路径为死代码,enforce_for_form 判定实际由 `isFormContext && grant.enforce_for_form===false → continue` 分支承担,语义等价(enforce=false 放行 / true 拒绝),无功能缺口;`isPublicForm` 标记仅 public-datas 打点、view 提交端点(dataInsertByViewId)刻意不打,认证用户走角色判定——符合 R1 注释意图。

## 6. 回归——PASS

- F05:变量 create(key/value)200、list 200(首测 400 系本路 payload 键名误用 `name`≠`key`,非回归)
- F07:snapshots list 200
- F08:private base(meta.isPrivate=true)创建 200
- F10:dashboard create 200、list 200
- `npx tsc --noEmit`:**exit 0**
- jest:**26/26 pass**(uniqueConstraintHelpers.Fork.spec + baseVariableValidators.Fork.spec)
- Base.delete/softDelete 挂 `Permission.deleteByBaseId` 清理(nc_permissions/nc_permission_subjects 双表),无孤儿行通道
- skipPermissionCheck 尊重:insert.ts bulk 循环与 bulkUpdate(raw)跳过;`skipValidationAndHooks=true` 仅 columns.service 内部列操作使用,无用户可达绕过

## 7. 代码复审(六 commit + fix 全 diff)——除上述 issue 外 PASS

- `fieldPermissionEntityIds`(BaseModelSqlv2.ts:10537-10557):三键(column_name/title/id)全收集 + Set 去重 + system/pk/FK/isSystemColumn 四重排除;R6 语义正确(歧义键过度拦截=安全方向);public 供 insert.ts 复用。updateByPk/nestedInsert/bulkUpsert/bulkUpdate/bulkUpdateAll/updateLTARCols + insert.ts 两处挂点齐全;raw/import(skipPermissionCheck)正确豁免;LTAR 列 title 键匹配(R5)落实。
- `checkPermission`(BaseModelSqlv2.ts:10559-10678):owner 直通→加载列表(fail-open)→逐 entityId 过滤 grants→无 grant continue→匿名(form)分支→多 grant 任一拒绝即 403(顺序无关);`req.context ?? this.context` 修实例缓存 context(R1);错误消息仅暴露字段 title、不泄漏 grant 结构。
- `Permission.update`:resolved-type 三守卫(nobody+subjects / role 缺 role / user 缺 subjects)全部写前校验;显式 null/'' granted_role 不被 `??` 吞掉(R4);nobody 落库清 granted_role;subjects 重建 + nobody 幂等清理;validateGrantShape 与 create 共享(enum/minimumRole/subject 形状)。
- `isAllowed`:PermissionRoleMap 映射 + owner 短路 + SDK evaluatePermission,与前端 `evaluateTableFieldPermission` 同一规则源;`getProjectRole(user)` 走 base_roles 最强角色,与 ncUsers ACL 角色注入一致。
- permissions.controller/service:v1+v2 双路径、@Acl 四 op、跨 base 归属校验(update/delete)、synced 字段拒配、FIELD+RECORD_FIELD_EDIT 范围锁死。
- 探针扫描:F02 触碰面 `console.log/debug/info` 零残留;前端 `isEeUI` 未翻转(仅 flag 驱动);`usePermissions` 懒加载 + base 切换清态 + force 刷新(R2);`useViewData` getter 惰性化(R1);性能:每次写请求 1+N(N=grant 行数)索引 meta 读,R1 注释明确弃 NocoCache 的理由成立,无回归实测(矩阵 96 请求无明显劣化)。

## 8. UI 段(camoufox-cli)——除上述 issue 外 PASS

网格为 canvas 渲染(`isCanvasTableEnabled = !ncIsPlaywright()`,smartsheet/grid/index.vue:240),列头菜单入口因 CLI 无右键/坐标点击且 canvas 样式被框架重置而无法自动化抵达——**测试手段限制,非产品缺陷**;弹窗本体经同组件入口(Details→Permissions tab,`DlgFieldPermissions`)完成全流程:

1. owner(:3000 登录 → Details → Permissions tab):tab 可见(gate 已解);字段列表 Name/Secret/Extra/Q2/QX 汇总渲染,Secret/Nobody 实时回显;弹窗**四选项**(Creators & up / Editors & up / Specific users / Nobody)渲染 ✓;Nobody→Save→行回显 Nobody ✓;Reset field permissions→回 Default ✓。截图:
   - `.work/ee-ce/ui-r7l4/l4-01-owner-dialog-secret.png`(弹窗 + 四选项 + 背景行 Secret=Nobody)
   - `.work/ee-ce/ui-r7l4/l4-02-owner-dialog-echo-reset.png`(Nobody 选中 + Reset field permissions 按钮 + 行回显)
2. editor:Details 无 Permissions tab(`isUIAllowed('fieldAdd')` 为 creator+,设计内);canvas 网格按设计不绘制 lock 图标(lock 属 DOM 网格 header Cell.vue;canvas 侧禁编辑走 `isCellEditable` 的 `isEditRestricted` 分支,useCanvasTable.ts:1904,dblclick 不开编辑器——该交互无坐标点击无法自动化,禁写行为已在 API 层全矩阵证实)。截图:`.work/ee-ce/ui-r7l4/l4-03-editor-grid.png`(editor 正常浏览 Matrix,渲染无异常)。
3. console error / 5xx 双零:两会话 `window.__uierrs`=[];UI 时间窗内 backend.log 无任何 5xx 状态行(43 条 ERR_AUTHENTICATION_REQUIRED 为未认证探测 401 类噪音,与本功能无关)。

---

## 附:测试痕迹

- 测试账号 owner/editor/creator@r7lane4.test(base R7L4F02 `po4lu2c82i2fdf9`);测试 grant 已全部删除(`GET …/permissions` = `[]`,fail-open 态还原),测试表 Matrix/Mx/FormR7 留存 nocodb-dev。
- 关键请求/响应原文留存于会话执行记录;矩阵脚本 `/tmp/r7l4_matrix2.sh`、表单脚本 `/tmp/r7l4_form4.sh`。
- tsc:`/tmp/r7l4_tsc.log`(TSC_EXIT=0);jest:`/tmp/r7l4_jest.log`(26 passed)。
