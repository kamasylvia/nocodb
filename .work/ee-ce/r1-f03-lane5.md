# F03 Data permissions — R1 复审报告（lane5，同规格独立编制）

审查对象：commit 7b10716231（主审）+ e1e996283c（HEAD 修复）；diff 范围 4b26d7a23f^..HEAD（F02 触碰面一并复审）。
环境：dev server :8080（rspack watch，工作树 == HEAD e1e996283c，F03 后端在线已用 403 新文案探针验证）；nocodb-dev @ qnap PG 18.2。测试脚本与上下文：`.work/ee-ce/r1l5/`（setup.sh / matrix.sh / matrix2.sh / visibility.sh / visibility2.sh / validation.sh / validation2.sh / ctx.json）。

## 结论

**issues（1 error + 2 minor）**：

1. `packages/nocodb/src/middlewares/extract-ids/extract-ids.middleware.ts:955-979（配合 :583 与 :1360-1377）`:v1 data 路由族绕过 TABLE_VISIBILITY 遮蔽——带 grant 时 editor 仍可按表 ID 读隐藏表数据:list/row/count/find-one 全 200:建议对 `params.tableName` 也解析 `tableIdToCheck`(现 969 行 `req.params.tableName` 分支因 ncBaseId 已在 :583 赋值而永不执行,ncTableId 不落地,F03 检查块整段跳过;data-alias-nested 与 old-datas `:tableName` 同族同修)`
2. `packages/nc-gui/components/dlg/Table/Permissions.vue:150-152(buildPayload)、224-237(save):SPECIFIC_USERS 未选任何用户时 payload=undefined:新建时 POST 空 body 得 400「Invalid entity undefined」、已有 grant 时 PATCH undefined body 静默 no-op 后仍弹成功提示:建议空 subjects 时 return null 并在 save 中跳过或禁用保存`
3. `packages/nc-gui/components/smartsheet/grid/Table.vue:343:在 computed getter 内调用 usePermissions():每次重估经其内部 `watch(baseId,…)` 注册新 watcher(泄漏)且偏离 setup 作用域消费模式:建议把 `const { isAllowed } = usePermissions()` 提升到 setup 顶层`

**观察项**（非 error，不阻塞）：
- O1 enforce_for_form 未在 DlgTablePermissions 暴露（API 默认 true = fail-closed，与 F02 裁剪一致；对齐 EE 完整语义时补开关）。
- O2 共享视图/表单公开路由豁免 VISIBILITY 遮蔽（extract-ids sharedViewUuid 分支 :283-291 不设 tableIdToCheck）——uuid 链接即显式授权，设计上可辩，建议产品确认。
- O3 Permission.list N+1 放大：中间件查一次 + 每个 checkPermission hook 再查（checkPermission 只认 req.permissions，不复用 context.permissions）；无 grant 时每写请求 2-3 次索引 meta 读，有 grant 时 subjects 逐行查。建议 checkPermission 先读 `reqContext.permissions`（F02 backlog ④ 延伸）。
- O4 Content.vue:2-5 头注释仍写「Table-level permissions arrive with F03 and are shown as defaults meanwhile」——F03 已落地，注释陈旧。
- O5（范围外 upstream bug，不计入 F03）：bulkUpsert 纯 update 批 → 500 `TypeError: Cannot read properties of undefined (reading 'Id')` at BaseModelSqlv2.ts:6065（afterUpdate）。复现：任意表 `POST /api/v1/db/data/bulk/noco/:baseId/:table/upsert` body `[{"Id":<活行pk>,"Col":val}]` → 500（行已物理更新）。owner 直通（绕过全部 hook）也 500、干净新表复现、`git diff 4b26d7a23f^..HEAD` 对 afterUpdate/chunkList/existingRecords/updatedPks/wherePk 零触碰（grep 0 命中）→ 非 F02/F03 引入。留证待 upstream/backlog。

## 逐项结果

### A. 集成测试（matrix/matrix2/visibility/visibility2/validation/validation2）

首跑 41+17=58 PASS；14 个 FAIL 经查全部为测试脚本形状错误（v2 删除路由实为 `DELETE /records` + body `[{"Id":x}]`，裸 id 400 是 CE 既有守卫；upsert 成功码 201；jq 空串≠"null" 判空失误），修正后重跑全过。数据分界全对：

1. **fail-open**：零 grant 时 editor/creator/owner 在 v2 单插 / v2 批插 / v1 单插 / v1 bulk / upsert 插入支路 / PATCH update / v2 单删 / v2 批删 / v1 单删 / delAll 全路径 200；grant 删除后下一请求立即恢复 200。
2. **ADD 矩阵**（v2 single / v2 bulk / v1 nested / bulk-alias / upsert 插入支路五路径一致）：
   - nobody：editor 403 / creator 403 / owner 200；update(PATCH) 不受 ADD 门控（200）。
   - role:editor：editor 200 / creator 200 / owner 200；role:creator：editor 403 / creator 200 / owner 200。
   - user(subject=editor)：editor 200 / creator 403。重复 (entity,entity_id,permission) 创建 400。
3. **DELETE 矩阵**：v2 单删（bulkDelete）/ v2 批删 / v1 delByPk / bulkDeleteAll(?where) 四路径同分界；nobody→editor 403、role:creator→editor 403 creator 200、role:editor→editor 200、user→指定者 200 他者 403、删 grant 后恢复；update 不受 DELETE 门控。
4. **upsert 拆分时机**：插入支路受 ADD 门控（nobody→403 实测）；纯 update 支路不要求 ADD（静态：`if (toInsert.length)` 门 + hook 位于 toInsert/toUpdate 拆分后；动态验证受 O5 upstream 500 干扰——500 发生在权限判定之后的 afterUpdate，且 owner 直通同样 500，permission 层放行已确认）。
5. **VISIBILITY**：
   - nobody：editor meta 404 / data 404 / count 404 / aggregate 404 / 表列表消失 / creator meta 404 / owner 全通；删 grant 后 editor meta 立即恢复 200（Everyone=删 grant 行语义成立）。
   - role:viewer：editor 200（editor≥viewer 可见——语义正确；初测预期写反已纠正）。
   - user subject：非 subject editor 404、subject owner 200。
   - 匿名：共享视图路由豁免（O2）；匿名直连非公开路由在 auth 层 401。
   - link 折叠：静态确认（relation-data-fetcher 10 处消费 hasTableVisibilityAccess，上游预接线，F03 未触碰）；live 联调被 CE link API 422（junction pk 校验，`[1]`/`[{"Id":1}]` 双形态均拒）卡住，未完成实链验证——记 E3-minor。
   - **泄漏（issue 1）**：`/api/v1/db/data/noco/:baseId/:tableId`（list）、`/:rowId`（读行）、`/count`、`/find-one` 在 nobody VISIBILITY 下全部 200 返回完整数据。按 title 访问 404 是无关既有行为（extract-ids:225 `Model.get` 按主键查、title 必失配 → tableNotFound，grant 前后均 404）。e1e996283c commit note 称「v1 GET returns 404 with nobody grant」与实测不符——该结论是误测（把 title 形状的无关 404 当成了遮蔽生效的证据）。
6. **校验对称**（create 14 项 + update 9 项分界全对）：field entity+TABLE key 400 / table entity+FIELD key 400 / 未知 entity_id 400 / 跨 base entity_id 400 / role 缺 granted_role 400 / 非法 granted_role 400 / ADD、DELETE 配 role:viewer（低于 minimumRole）400 / VISIBILITY 配 viewer 200 / user 缺 subjects 400 / team subject 400 / nobody+subjects 400 / 非法 granted_type 400 / 非法 subject shape 400；PATCH nobody+subjects 400 / PATCH 转 role 缺 role 400 / PATCH DELETE→viewer 400 / PATCH 转 user 无 subjects（resolved-type）400 / granted_role 显式 null 400 / role→nobody 200 且 granted_role 清为 null（DB 状态 `null|nobody` 实证）/ nobody→role 200 / editor 调 PATCH 403（ACL creator+）。
7. **回归**：F05 variables GET 200 / F07 snapshots GET 200 / F10 dashboards GET 200 / F08 bases 列表 200 / F02 字段权限：nobody FIELD grant 下 editor PATCH 受限字段 403、owner 200、删 grant 后 editor 200。
8. **tsc**：`npx tsc --noEmit` exit 0、0 输出。**jest**：26/26（2 suites，Fork 桶）。

### B. 代码复审（4b26d7a23f^..HEAD 全 diff + F03 主提交逐 hunk）

- **fieldPermissionEntityIds**（BaseModelSqlv2.ts:10580-10611）：Set 去重、system/pk/ForeignKey/`isSystemColumn` 四重过滤、column_name/title/id 三键全收集（R6 碰撞防旁路），正确。
- **checkPermission**（:10620-10734）：owner 直通 → 权限清单（req.permissions 优先，否则 Permission.list）→ 空清单 fail-open → 逐 entityId 过滤 grants → 任一 deny 即 403（multi-grant 顺序无关，首 deny break）；isFormContext 对匿名走 enforce_for_form、对登录用户跳过 opt-out grant；403 文案按 permission 泛化（permissionDeniedMessage），无敏感泄漏。
- **update() resolved-type 三守卫**（Permission.ts:360-434）：targetType 解析（body 优先/回落 existing）→ nobody+subjects 拒（写前）→ role 缺 role 拒（显式 null 以 `''` 落库判定，防 null-role 行）→ user 缺 subjects（`data.subjects ?? existing`）拒 → nobody 落库清 granted_role + subjects 重建后兜底再删 subjects。顺序与幂等正确，live 全验。
- **validateGrantShape**（Permission.ts:243-308）：create 带 requireSubjectsForUser；enum / minimumRole（SDK PermissionMeta 驱动，VIEWER/EDITOR/EDITOR 三 key 各自生效）/ subject shape / nobody+subjects 四类校验 create/update 共享，对称。
- **permissions.service 解封**（:73-96）：TABLE entity 三 key 白名单、Model 存在、base 归属、synced 拒配、重复 (entity,entity_id,permission) 拒——与 FIELD 分支对称；update/delete 保留 base 归属校验。
- **挂点覆盖**：insert.ts single(:77)/bulk(:362，`!skipPermissionCheck` 包裹，import/copy 免检)/nestedInsert(:3079，isFormContext)/bulkUpsert(:3873，拆分后只查 toInsert) + delByPk(:2251)/bulkDelete(:4977，先于裸原语 400 守卫)/bulkDeleteAll(:5546)。调用方 grep 确认 delByPk/bulkDelete/bulkDeleteAll 仅 4 个用户路由入口（datas 231/1275、old-datas 153、data-table 338、bulk-alias 反射），trash 永久清（permanentDeleteByIds）与 F07 快照删（Base.softDelete）不经此三方法——「无需 skip 通道」的判断成立。
- **extract-ids F03 块**（:1360-1377）：空权限清单短路（fail-open 零开销）、`!isServiceUser(req.user)` 豁免、404 非 403、匿名经 helper 回落 default visibility——块本身正确；缺口在其上游 ncTableId 赋值链（issue 1）。
- **前端**：Node.vue gate 去 isEeUI/showEEFeatures（blockTableAndFieldPermissions 驱动）+ 弹窗 v-if 解封；DlgTablePermissions 三 key 三型（role/user/nobody；VISIBILITY Everyone=DELETE grant 行）+ reset-all + save 后 force refetch，Everyone 默认值修复（e1e996）在位；Content.vue 三行摘要 + Configure 入口；useExpandedFormStore 去 `!isEeUI` 短路；i18n en/zh 补 `whoCanAddRecords`/`whoCanDeleteRecords`。无 console./debugger 残留（diff grep 0）。minor 见 issues 2、3。
- **性能**：除 O3 外无回归面（VISIBILITY 中间件一次索引 meta 读 + 空清单短路）。

### C. 外部限制（E3）

- link 折叠 live 验证未完成：CE mm link API POST 422（`ERR_INVALID_PK_VALUE` junction pk 校验）——建链未成功，折叠行为仅静态覆盖。有诊断证据，非实现缺陷。
- bulkUpsert 纯 update 500（O5）：上游路径，静态证据链完整（diff 零触碰 + owner 直通复现 + 干净表复现），不阻塞 F03 判定。

## 复审覆盖度自述

- 集成：6 个后端挂点 × 3 grant 型 × 3 角色 × 5 条 insert 路径 / 4 条 delete 路径 / upsert 双支路；VISIBILITY 4 消费面（meta/data/list/count+agg）+ grant 生命周期往返；校验对称 23 项；fail-open 双向；跨 base entity_id；ACL 层（editor 拒写）。
- 静态：F03 主提交 12 文件全 hunk + F02 触碰面 diff（27 文件）关键函数级核对；调用方/消费方 grep 交叉。
- 未覆盖：MCP token 面（service user 豁免仅静态）、shared base 两档 viewer 语义（依赖 public base 搭建）、import skip 通道（import.service 内部路径，静态确认 skipPermissionCheck 透传）。
