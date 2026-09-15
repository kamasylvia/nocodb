# F02 R7 lane2 报告(功能全量集成测试 + 全 diff 代码复审)

审查对象:4b26d7a23f..0711660b8c(6 commit,六文件面 24 files +1626/-56)。隔离执行,未读他路报告。
环境:dev server http://localhost:8080(uptime 2154s 起,未重启);DB nocodb-dev(qnap.elf-balance.ts.net:5432,全程显式硬编码库名);独立账号 own/ed/cr/vw@l2f02.local;测试 base p0ln1icojxn7ckm(l2f02,测后软删)。

## 结论:PASS

无 error。R6 修复实测生效;全矩阵/fail-open/校验对称/公共表单/回归全过;tsc 0;jest 26/26;diff 无探针残留。1 条非 F02 既有缺陷 + 2 条低影响观察(见文末)。

---

## 1. R6 修复验证(重点)——通过

构造:表 f02t2,列 `cj3uhzmcdqyciso`(title=Q2, column_name=q2_decoy,诱饵未受限)+ `czt2l1i540f6thp`(title=QX, column_name=Q2,受限,nobody grant)。DB 落库核对无误。

| 步骤 | 请求 | 实测 | 判定 |
|---|---|---|---|
| 1a | editor PATCH 碰撞键 `{"Q2"}`(grant 前) | 200 | fail-open 基线 ✓ |
| 1c | editor PATCH 碰撞键 `{"Q2"}`(grant 后) | **403** `Forbidden - ...field QX` | **R6 修复生效**(旧 find() 单命中会命中诱饵 title=Q2 → 200 绕过) |
| 1d | editor PATCH title 键 QX | 403 | 三键收集 ✓ |
| 1e | editor PATCH id 键 czt2l1i540f6thp | 403 | 三键收集 ✓ |
| 1f | editor PATCH decoy 专用键 q2_decoy | 200 | 歧义键之外不过拦 ✓ |
| 1g | owner 同碰撞载荷 | 200,读回 Q2/QX 双列同值 ownerWrite | 歧义键双列写入+双列都检,语义正确 ✓ |

实现核对(`BaseModelSqlv2.ts:10529-10558`):双循环 Set 收集全部命中,column_name/title/id 三键匹配,`system/pk/ForeignKey/isSystemColumn` 豁免;`checkPermission:10611-10677` 逐 entityId 逐 grant,任一 deny 即 403(顺序无关)。错误消息仅含字段 title,无内部 id 泄漏。

## 2. 全矩阵 grants×roles×写路径——通过

无碰撞对照表 f02t1(Title/QX/Free),QX=`cri22d9yam3qppu`。

**Round A nobody grant**:editor 六路径全 403 —— v1 updateByPk(PATCH /api/v1/db/data/noco/b/t/1)、v2 单条 POST /records(insert.ts 钩子)、v2 数组 bulkInsert、v2 数组 bulkUpdate、v1 bulkUpdateAll(/all?where)、v1 bulkUpsert(/upsert);creator v1 PATCH 403 + v2 bulkInsert 403(nobody 拒一切非 owner,正确);owner v1 PATCH 200;editor 改未受限列 Free 200(字段级隔离)。

**Round B role(creator)**:editor v1 PATCH/bulkInsert/bulkUpdateAll/bulkUpsert 全 403;creator v1 PATCH 200、upsert 新行含 QX 201。

**Round C role(editor)**:editor v1 PATCH 200、bulkUpdateAll 200(`{count}` 返回)、v2 单条 insert 200。

**Round D user(subjects=[creator])**:editor updateByPk 403 + v2 insert 403;creator PATCH 200 + bulkUpdate 200;owner 200。

**Link 路径**(HasMany 列 LNK,grant=nobody):editor nestedLink POST /links/:colId/records/1 → 403;editor nestedUnlink → 403;owner nestedLink → 201;删 grant 后 editor → 201。addChild/addLinks/removeLinks/removeChild/reorderLink 同一 checkPermission(colId 直传)代码同构。

**legacy /data/:tableId**(datas.controller 挂载点,dataInsertByViewId → baseModel.insert → insert.ts:69 钩子,R1 cookie 修复覆盖):editor 403 / owner 200 —— 证明 cookie 透传后权限可解析(修复前 null user 会 fail-open)。

## 3. fail-open——通过

- 无 grant:editor PATCH QX 200(基线)、v1/v2/links 全路径放行。
- grant 删除(DELETE 200,DB count=0)后 editor 下一请求 v1 PATCH 200 + v2 insert 200 + link 201 —— list 无缓存(R1 deliberate),立即生效。
- enforce_for_form 切换 同样下一请求即生效(T5a 403 → PATCH false → T5d 200)。

## 4. 校验对称——通过

create(POST /bases/:id/permissions):nobody+subjects 400 / role 缺 granted_role 400 / user 缺 subjects 400 / granted_role=superadmin 400 / granted_role=viewer(低于 minimumRole EDITOR)400 / entity=workspace 400 / entity_id 不存在列 400 / entity=table 400(F03 未做拒,防 inert 行)/ 重复 (entity,entity_id,permission) 400(实测两次创建被拒)。

update(PATCH /permissions/:id):nobody 行补 subjects 400 / nobody→role 缺 role 400 / granted_role=null 400 / granted_role='' 400 / role→user 无 subjects 400 / user+team subject 400 / granted_role=bogus 400;合法 nobody PATCH 200 且行内 granted_role 清 NULL(重建后兜底删 subjects 生效)。

ACL:editor POST/PATCH permissions → 403(creator+ 配置);editor GET permissions → 200(editor+ 可读,锁图标依赖);匿名 GET → 401;跨 base PATCH → 404;service 层 base 归属校验在码(existing.base_id !== baseId)。

## 5. 公共表单——通过

shared form(uuid 8ad1a96c…)匿名 POST /api/v2/public/shared-view/:uuid/rows:
- enforce_for_form=true + 受限 QX → **403**(public-datas isPublicForm 标记生效);
- 同会话仅 Title → 200;
- PATCH enforce_for_form=false 后 QX → 200(匿名豁免语义)。
- 视图域登录提交(v2/v1 view insert,故意非 form context):editor 403 / owner 200。

## 6. 回归——通过

- F05:GET/POST/DELETE /bases/:id/variables 200(key 正确载荷;首测 400 系本路 payload 误用,非回归)。
- F07:GET /bases/:id/snapshots 200。
- F10:GET/POST/DELETE /bases/:id/dashboards 200。
- F08:GET /bases/:id 200,is_private 列在位。
- `npx tsc --noEmit`(packages/nocodb):**exit 0**。
- jest:2 suites / **26 passed, 26 total**(baseVariableValidators.Fork + uniqueConstraintHelpers.Fork)。
- 测试环境清理:变量/dashboard 删除、base 软删、全部 grant 行删除(DB 核对 count=0)。

## 7. 代码复审(全 diff)——无 error

- **fieldPermissionEntityIds**:三键全收集+Set 去重+四重豁免(system/pk/ForeignKey/isSystemColumn);public 供 insert.ts 复用;IBaseModelSqlV2 接口同步。
- **checkPermission**:owner 直通 → req.permissions(MCP 预载)或 Permission.list(R1 修复 req.context 而非 this.context 作 load 标记位)→ 无 grants continue → 匿名分支(enforce_for_form 全 false 才豁免)→ 多 grant 任一 deny 即 403;标签仅 title。
- **Permission.update**:resolved-type 三守卫(nobody+subjects / role 缺 role / user 缺 subjects)全部先验证后写;R4 `'granted_role' in data` 键存在语义,显式 null/'' 不被 ?? 吞;nobody 切换清 granted_role;subjects 重建后兜底删(nobody 不变量与载荷顺序无关)。
- **validateGrantShape**:create(requireSubjectsForUser)/update 共享;enum/minimumRole/subjects 形状全验;service 层 team subject 在 create/update 双侧按 resolved-type 拒。
- **去重/归属**:create 拒重复三元组;update/delete 校验 base 归属。
- **skipPermissionCheck 通道尊重**:import.service 3 处 true、bulk-data-alias 透传、bulkInsert/bulkUpdate/bulkUpsert raw 跳过、bulkUpdateAll skipValidationAndHooks 跳过(内部列改写豁免,方向安全);duplicate 链路确认不传 skip,经 owner 语义/fail-open 落安全侧。
- **Base.delete/softDelete** 挂 Permission.deleteByBaseId。
- **探针**:diff 内 console.*/debugger 0 处。
- **前端**:gate 全部 flag 驱动(useEeConfig block=false;View.vue tab 三处;Details.vue;ColumnMenu);usePermissions fail-open+owner 直通+per-base 懒加载+写后 force 刷新(R2)+base 切换清态;useViewData lazy getter 修 grant 加载前冻结(R1);Form.vue 表单隐藏 isAllowedToEdit===false;Content.vue 过滤(system/pk/FK)与后端豁免一致;Tooltip 接线且无 entityId 保底放行;ColumnMenu DlgFieldPermissions 传参 field-id/title/uidt 与 props 匹配(另附 :field 落 attrs,无害);dlg 保存/删除走 create/patch/delete + loadPermissions(true);onBeforeUnmount 复位 visible。

## 观察项(非 error,不计违反)

1. **bulkUpsert update 分支 500(上游既有,非 F02)**:`POST /api/v1/db/data/bulk/.../upsert` 命中已存在行时 500 `afterUpdate (BaseModelSqlv2.ts:6013) Cannot read properties of undefined (reading 'Id')`,栈 bulkUpsert:4171 → afterUpdate。归属证据:调用点属上游同步 commit 58ed76ab44,F02 diff 对该区域零触碰(git diff hunks 仅 2807/3037/3625/4447/4657/4700/10426);owner 在 F02 无关旧表(base p1ln9rz5oc4tzk5/f02tbl)复现同 500;upsert insert 分支 201 正常;权限层在 500 前已正确拦截(editor/creator 403)。建议:另行记录上游问题,不阻塞 F02。
2. **列删除孤行(数据卫生)**:Model.delete/Column.delete 不清理 nc_permissions 中指向已删列的 grant 行。影响评估:孤行永远 inert——fieldPermissionEntityIds 仅映射现存列,nanoid id 无复用,无 bypass 也无误拦;仅行累积。
3. **Permission.list N+1**:每 grant 行一次 subjects 子查询,R1 注释明示 deliberate cache-free(正确性优先);当前量级无碍,grant 规模化后可再评。

## 证据索引

全部 HTTP 状态码/响应摘录见会话执行记录;关键行号:fieldPermissionEntityIds `BaseModelSqlv2.ts:10529`;checkPermission `:10568`;updateByPk 挂点 `:2815`;nestedInsert `:3057`;bulkUpsert `:3658`;bulkInsert `:4498`;bulkUpdate `:4505`;updateLTARCols `:4727`;bulkUpdateAll `:4789`;links `:6447/:6850/:8732/:8749/:8767`;insert.ts `:69`;Permission.ts 全文;permissions.controller/service 全文;acl.ts permissionScopes + editor permissionList。
