# r7-f02-lane5 — F02 Edit field permissions R7 轮复审(功能全量集成测试 + 整个 diff 代码复审)

审查对象:4b26d7a23f(实现)+ e85a421d92(R1)+ 3b9dcbdbc6(R2)+ a8fc2c2966(R3)+ b95fbf7f74(R4)+ 10e8d92729(R5)+ 0711660b8c(R6 修复,重点验证)。
环境:nocodb-dev 后端 dev :8080(未重启);库 `nocodb-dev`(qnap.elf-balance.ts.net:5432,PG 18.2,严禁 nocodb 生产库,库名显式硬编码);测试 base `pf89go4i4uskhw5` / 4 角色(editor/creator/viewer/owner)。

## 结论

**PASS**(0 error;2 条 observation,均无 API 可达路径或属已记录取舍,不算 error)

## 逐项结果

### 1. R6 修复验证(重点)— PASS

交叉重名布局:Collide 表 `colY{title:Q2, column_name:colY, id:c0qchq…}` 前置诱饵 + `colX{title:QX, column_name:Q2, id:cxas3l…}` 受限列(nobody grant);控制列 Ctl。

| 用例 | 路由 | 期望 | 实测 |
|---|---|---|---|
| editor PATCH 劫持键 `{"Q2":…}`(colX.column_name=colY.title) | v2 /records | 403(旧 build find() 首中诱饵 → 200) | **403** `Forbidden - You don't have permission to edit the field QX` |
| owner 同载荷 | v2 /records | 200 | **200** |
| editor title 键 `{"QX":…}` | v2 /records | 403 | **403** |
| editor 诱饵自身键 `{"colY":…}`(未受限) | v2 /records | 200 | **200** |
| editor 对照列 `{"Ctl":…}` | v2 /records | 200 | **200** |
| 劫持键 insert editor / owner | v1 /db/data/noco/:base/:tid | 403 / 200 | **403 / 200** |
| 劫持键 insert editor / owner | v3 POST /records | 403 / 200 | **403 / 200** |
| 劫持键 PATCH editor / owner | v3 PATCH /records(`[{"id":1,"fields":{"Q2":…}}]`) | 403 / 200 | **403 / 200** |

- 错误消息报受限列 title(QX),无内部 id/结构泄漏。
- 结论:**三键 find()→全收集改造后,歧义键过度拦截(安全方向),劫持通道全路由封闭。**

### 2. 全矩阵(grants × roles × 写路径)— PASS(86/86)

对照表 Normal{N1, N2},grant 作用于 N2;5 grant × 4 角色 × 6 路径。脚本 `/tmp/r7f02-matrix.py`。

| grant | editor | creator | viewer | owner |
|---|---|---|---|---|
| nobody | 403 | 403 | 403* | 200 |
| role=editor | 200 | 200 | 403* | 200 |
| role=creator | 403 | 200 | 403* | 200 |
| user=[editor] | 200 | 403 | 403* | 200 |
| user=[outsider] | 403 | 403 | 403* | 200 |
| 无 grant(fail-open) | 200 | 200 | 403* | 200 |

\* viewer 的 403 来自 CE 原生 ACL(dataUpdate 需 editor+;消息 `You do not have permission to update data with the roles: Viewer`),与 F02 无关;grant 存在时 viewer 403 由 F02 判定,分界一致。

写路径 × (editor, owner) 全覆盖:v2 单条 PATCH / v2 insert / bulkInsert(v1 bulk)/ bulkUpdate / bulkUpdateAll(/all)/ bulkUpsert(/upsert,成功语义 201)/ v1 单条 insert — 拦截/放行分界全对(如 role-creator:bulk 各路径 editor 全 403、owner 全成功;user-outsider editor 全 403)。
邻列不受牵连:nobody grant 在 N2 时 editor 写 N1/CTL 均 200(单列精确拦截)。
grant delete 后下一请求放行:矩阵 clear_grant 后 fail-open 段实测 200。

### 3. 校验对称 — PASS(31/31)

脚本 `/tmp/r7f02-validate.py`。create × 15 项全 400:nobody+subjects / user 缺 subjects / user 空 subjects / role 缺 granted_role / granted_role 非法枚举 / viewer·commenter 低于 minimumRole(EDITOR) / granted_type 非法 / 非法 entity / 非法 permission key / 列不存在 / table-entity 拒(F02 scope) / subject 形状(type 非法、缺 id) / team subject 拒 / 重复 grant 拒。
update × 8 项全 400:nobody+subjects / role 显式 null granted_role / 空 granted_role / 非法枚举 / 低于 minimumRole / 切 user 无 subjects / granted_type 非法 / user grant 补 team subjects(R4 resolved-type)。
合法迁移:nobody→role editor 200、role→nobody 200、nobody 行无残留 granted_role(实测 'None')。
ACL 分界:editor create 403 / creator create 200 / editor list 200(读放行) / viewer list 403。

### 4. 公共表单 — PASS(4/4)

脚本 `/tmp/r7f02-form.py`;PubForm shared view(uuid 6b5b7f1b…),受限列 N2。

| 用例 | 实测 |
|---|---|
| 匿名提交含 N2,enforce_for_form=true | **403** |
| 匿名提交含 N2,enforce_for_form=false | **200** |
| 匿名提交仅 N1(未触受限列),enforce=true | **200** |
| 已认证 editor 走 view submit 提交 N2,enforce=true | **403** |

datas.service dataInsertByViewId 由 `insert(body, null)` 改传 cookie 的修复生效(认证用户不再绕权)。

### 5. link 系 5 方法 — PASS

LinkFrom(lnk→LinkTo, hm)+ LinkTo(mlnk→LinkFrom, mm 有序)。

| 操作 | 路由 | editor(nobody grant) | owner |
|---|---|---|---|
| addLinks | v2 POST /links/:colId/records/:rowId | 403 | 201 |
| removeLinks | v2 DELETE 同路径 | 403 | 200 |
| addChild | v1 /data/noco/:base/:tid/:rowId/hm/lnk/:ref | 403 | 200 |
| removeChild | v1 DELETE 同路径 | 403 | 200 |
| reorderLink | v2 internal op nestedDataReorder(mm 有序链) | 403 | 200 |

hm 链 reorder owner 得 422 `This link does not support ordering` — 产品语义(hm 无排序),非权限拦截问题;权限 gate 在服务内先于该业务校验触发(editor 403 实证)。

### 6. 回归 — PASS

- F05 变量:list 200 / create(key 字段)/ patch / delete 全 200。
- F07 快照:list 200。
- F08 私有 base:`{"type":"database","is_private":true}` 创建成功,editor 访问 404 / owner 200,删除 200。
- F10 dashboard:create / get / delete 全 200。
- `npx tsc --noEmit`:**exit 0**。
- `pnpm test`(jest):**2 suites / 26 tests 全过**。
- base 删除级联:删测试 base 后 `nc_permissions` / `nc_permission_subjects` 计数均 0(deleteByBaseId 生效)。

### 7. 代码复审(整个 F02 diff,21 文件 +1621/−53)

- **fieldPermissionEntityIds**(BaseModelSqlv2.ts:10522):Set 全收集 + system/pk/ForeignKey/isSystemColumn 四重过滤 + 三键(column_name/title/id);R6 后无首中劫持;歧义键 over-block 为安全方向 ✓
- **checkPermission**(BaseModelSqlv2.ts:10568):owner 直通 → `req.context ?? this.context`(修 BaseModelSqlv2 实例缓存导致 context 陈旧,R1)→ req.permissions 优先 / fallback Permission.list → 无 grant fail-open → 每 entityId 独立收集 grants,任一 deny 即拒(顺序无关)→ anonymous 仅在 form 上下文尊重 enforce_for_form,非 form 匿名直接拒 ✓
- **Permission.update**:共享 validateGrantShape → resolved-type 三守卫(nobody+subjects 拒 / role 需 granted_role 且 `'granted_role' in data` 显式 null/空不滑过(R4)/ user 需 subjects 可沿用 existing)→ nobody 清 granted_role + 幂等清 subjects(R3,重建后兜底)✓
- **validateGrantShape 共享**:enum/minimumRole/subjects 形状/nobody+subjects 互斥;create 用 requireSubjectsForUser、update 允许沿用 ✓
- **挂点覆盖**:updateByPk(2815)/ nestedInsert(3057,v1+public form 汇聚)/ bulkUpsert(3653,!raw)/ bulkInsert(4505,!raw)/ updateLTARCols(4735,常挂)/ bulkUpdateAll(4790,!skipValidationAndHooks)/ insert.ts 单条(65)+ bulk 分支(341,尊重 skipPermissionCheck);import/copy skip 通道保留 ✓
- **Base.ts** delete/softDelete 双挂 Permission.deleteByBaseId ✓(实测清零)
- **ACL**:permissionList editor+ 只读、Create/Update/Delete creator+,noco.module 注册 ✓
- **前端**:useEeConfig blockTableAndFieldPermissions=false;View.vue/Details.vue/ColumnMenu gate 改 flag 驱动(未全局翻 isEeUI);usePermissions 懒装载 + base 切换清 stale + force refetch(R2);useViewData isAllowedToEdit 惰性 getter(R1);Permissions.vue 单字段弹窗(PATCH 载荷中 entity/entity_id/permission 被 update() extractProps 忽略,不会误改绑定);Content.vue 纯展示 ✓
- **残留扫描**:diff 内 console.log/debugger/FIXME 零命中;R5 误入的 `PATCH`/`-X` 垃圾文件已删 ✓;`[CE-EE]` 标记 43 处 ✓
- **错误消息**:仅字段 title,无 id/SQL/内部结构泄漏 ✓

### Observation(非 error)

1. `packages/nc-gui/composables/usePermissions.ts:isAllowed/getPermissionSummary` — 多 grant 时仅评估 `grants[0]`,与后端「任一拒绝即拒」在多 grant 场景不一致;但 permissions.service.create 有 (entity, entity_id, permission) 唯一性校验(400),API 无法构造多 grant,仅 DB 直插可触发。防御深度项,建议后续前端改为遍历全部 grants(任一 deny 即 false)。
2. `packages/nocodb/src/models/Permission.ts:list` — 每 grant 一次 subjects N+1 查询、无缓存(R1 注释明示 deliberately cache-free,正确性优先);数据写路径每次约 2+N 次小索引查询。grant 行少量时可接受;若未来 grant 数量增长可加 per-request/context 级缓存。

### 备注

- UI 段(camoufox)不在本 lane 任务书规格内(任务书 6 项集成测试全为 API+构建核验);nc-gui dev :3000 实测 200 可达,UI 专项由其它路覆盖。
- 测试痕迹:helper `.work/ee-ce/r7f02-db-env.sh`(运行时拉 Infisical,无硬编码凭证);测试 base/表已删(base 删除同时验证权限行级联);测试账号 r7f02l5-*@test.local 留存 nocodb-dev。
