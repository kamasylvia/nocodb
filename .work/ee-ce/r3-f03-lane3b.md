# R3 终局收敛轮 — lane3(F03 Data permissions:功能全量集成测试 + 全 diff 代码复审)

> 落盘说明:任务书指定路径 `r3-f02-lane3.md` 被上一功能(F02 R3 收敛轮)历史归档占用,`r3-f03-lane3.md` 亦已存在,故按 lane 加后缀落 `r3-f03-lane3b.md`,不覆盖任何历史归档。

审查范围:4b26d7a23f..HEAD(F02 全部修复 + F03 实现 7b10716231 + R1 e1e996283c/2f5a57b0d3/0a3e5fdab4 + R2 c7a242cdf3 + chore 6cc43e0b81)。隔离:只读 TASK.md / 仓根 AGENTS.md / f02-f03 research / 源码 / git diff。
方法:live 实测(dev server :8080 + nocodb-dev,前缀 f02r3c-*,owner/editor/commenter/viewer 四号 + main/hidden 两表 + shared form view)+ 全 diff 静态审 + tsc/jest。

## 结论

**issues(2)**

1. **[error] duplicate/快照 restore 副本不携带权限 grants — `packages/nocodb/src/modules/jobs/jobs/export-import/import.service.ts:172-182`**
   `importPermissions()` 是空 stub(仅注释 `//  create permissions`)。上游 CE 预埋(commit 87cb85ea32 "feat: include permissions on duplicates",同 Permission.ts stub 模式),fork 未实装。export 侧 `export.service.ts:718-760` 序列化完备(TABLE+FIELD grants、subjects、enforce_*),import 侧 `import.service.ts:1985-1994` 调用后不落库。
   **实测**:原 base 持 `TABLE_VISIBILITY nobody` grant → owner duplicate → 副本 `GET /permissions` = `[]`(两次复现:副本 p73ghsxqartgv3n / p51d6cuet9kpubh)。F07 快照走同一 duplicateBaseJob → restore 产物(pivfmljdgdir0jl)同样丢 grants。
   **影响**:副本 fail-open(默认 Everyone/editors),owner 需手动重配;f03-research §2.2「duplicate/restore 自动携带表权限」判断失实(export 携带、import 落空)。
   **建议**:实装 importPermissions(按 export shape Permission.insert + subjects 映射 + idMap 换 id);或明确裁剪记 fork 限制(副本权限重置,owner 手动重配)。附带:`import.service.ts:1988` 的 `break` 应为 `continue`(首 model 无 permissions 会跳过后续所有 model 的导入)。

2. **[minor] `packages/nc-gui/components/smartsheet/grid/Table.vue:336-346` computed 内 inline 调用 `usePermissions()`**
   `isAddingEmptyRowAllowed` 在 computed getter 内 `usePermissions().isAllowed(...)`。usePermissions 体内含顶层 `void loadPermissions()`(usePermissions.ts:71)与 `watch(baseId, ...)`(:81)——每次 computed 重算注册一个新 watcher(非 setup 上下文,无人 stop)→ watcher 泄漏累积;且 `?? true` 冗余(isAllowed 恒返回 boolean)。
   **建议**:`const { isAllowed } = usePermissions()` 提到 setup 顶层(Form.vue:66 同款),computed 只调 isAllowed。

## 观察项(非 error,供裁决/巡检)

- **enforce_for_form 开关未暴露**:DlgTablePermissions 的 `KeyState.enforceForForm` 加载后从不消费(dead field),弹窗无开关;API 层完整(PATCH 双向实测)。默认 true 语义安全。研究 §6.9 建议暴露,实施裁剪。建议删 dead field 或补开关。
- **service user 不对称**:extract-ids VISIBILITY gate 有 `!isServiceUser(req.user)` 豁免(middleware :1382);ADD/DELETE checkPermission 无 service-user 豁免(BaseModelSqlv2.ts:10636 仅 owner 直通)。grant 存在时 automation/sync 用户写入被拒。研究建议 v1 放行,实施未做——语义名实相符,记 fork 限制即可。
- **R2 fallback 段为死代码**:extract-ids.middleware.ts:1110-1120(`!ncTableId && params.tableName`)实际不可达——主路径 `tableId = params.tableId||params.modelId||params.tableName||query.tableId`(:188)已含 tableName,且 `Model.get` 仅按 id 解析,title 传参在主分支即抛 tableNotFound(实测 v1 title 404)。无害防御;v1 data 链路以 table id 可用且 grant 拦截实测生效(legacy 路径另有 tableIdToCheck 机制 :990-996)。
- **SPECIFIC_USERS 空 subjects 保存语义**:DlgTablePermissions `buildPayload` 返回 undefined → save 静默删除既有 grant(变默认)。边界可议,非阻塞。
- **v1 bulkUpsert 纯 update 批 500**(上游/调用姿势,非 F03):owner 与 editor 同炸(`undefined reading 'Id'`);mixed 批 403 证明 F03 hook 在 upsert 拆分后正确触发、纯 update 批正确跳过。
- **v1 delByPk 偶发 500**(E3 观察):audit.ts:1100 `extractColsMetaForAudit` 读 null data(afterDelete ← delByPk:2674),间歇性复现 4 次后自愈(同型请求连测 3 次全 200),行删除已生效、仅响应 500。F03 diff 未触碰该数据流(delByPk 仅头部加 checkPermission,datas.service 零改动)。建议 patrol 复现再判。

## 集成测试证据(全部通过,除非另注)

环境:nocodb-dev(base p5y15zfxmlc0n0r,main/hidden 两表;owner/editor/commenter/viewer;instance super 已清除、JWT 重签后实测,首轮 super 污染数据全部废弃重测;测试 base/副本已清理)。

**fail-open / ACL**
- 无 grant:editor v2 insert 200、viewer dataList 200;DELETE/ADD grant 删除后写入恢复 200
- editor `permissionCreate` 403(creator+ ACL);editor `permissionList` 200;viewer `dataInsert` 403(角色 ACL 非 permission)

**grants 校验对称**
- 重键 (entity,entity_id,permission) 400;非法 permission/entity 400;跨 base table 400;不存在的 table 400
- minimumRole:ADD role:viewer POST/PATCH 均 400("granted_role viewer is below the minimum role for TABLE_RECORD_ADD");PATCH role creator→editor 200
- nobody+subjects:create/PATCH 400("subjects are not allowed on nobody grants");user grant 缺 subjects 400 → user→nobody→user 往返 subjects 无复活路径(model 层 delete subjects + service 必填双保险,R5 修复有效)

**TABLE_RECORD_ADD**
- nobody:editor v2 单条 403 / v2 bulk 数组 403 / v1 data-alias insert 403;owner 直通 200;文案 "You don't have permission to create records in f02r3c_main"
- role creator:editor 403;role editor:editor 200;user [editor]:editor 200
- bulkUpsert mixed(插入+更新)批 403(拆分后检查,纯 update 批不误伤)
- skip 通道:insert.ts bulk hook 在 `if (!skipPermissionCheck)` 块内(源码核验)→ F07 快照 create+restore 实测不被自拦(completed)

**TABLE_RECORD_DELETE**
- nobody:editor v2 bulkDelete(`{"Id":10}`)403 / v1 data-alias(按 table id)403;owner 200;文案 "delete records in …"
- DELETE grant 移除后 editor v1 delete 200

**TABLE_VISIBILITY**
- nobody:editor/viewer 表列表消失、直连 `/meta/tables/:id` 404、v2 data GET/POST 404、v1 data/meta 404;owner 全通;404 遮蔽一致(tableNotFound)
- role viewer:viewer 200;editor 200(**正确语义**——"Viewers & up"=viewer 及以上,UI visibilityOptions 已排除 EDITORS_AND_UP 档)
- user [editor]:editor 200、viewer 404
- Everyone=删 grant 往返(grantId 删后列表恢复、viewer 可读)

**enforce_for_form(匿名 shared form)**
- nobody-ADD true→匿名提交 403;PATCH false→200(行落地);回 true→403

**F02 回归**
- FIELD nobody Qty:editor PATCH 403("edit the field Qty");Name PATCH 200

**duplicate / F05-F10 回归**
- owner duplicate 两表全拷(grants 随 copy 失败→issue 1)
- F05:variables create/list ✓;F07:snapshot create→completed、restore 产物 base ✓;F10:dashboards list ✓;F08 base meta ✓

**静态/门禁**
- 后端 `tsc --noEmit` exit 0(0 错);后端 jest **26/26**(2 suites,Fork 桶)
- 前端 vitest `test/table-field-permission.test.ts`:3 次未跑起(vitest 4 forks worker "Timeout waiting for worker to respond";threads pool 重试同型)——**E3 环境限制**,非代码失败,诊断日志 `.work/ee-ce/tmp-lane3/vitest*.log`
- console.log/error 残留:Permission.ts / permissions.service.ts / BaseModelSqlv2.ts 均 0

## 与 f03-research 偏差清单

| 研究断言 | 实测 |
|---|---|
| §2.2 duplicate/restore 自动携带表权限 | ❌ import stub 不落库(issue 1) |
| §6.9 弹窗暴露 enforce_for_form 开关 | 未做,API 可改(观察项) |
| §5 建议服务用户放行 ADD/DELETE | 未做,记 fork 限制(观察项) |
| 其余(后端挂点 6 处、VISIBILITY data 路由遮蔽、v1/v2 全链、UI gate 三处、legacy Table.vue 补一行、Content.vue 表级摘要) | ✅ 全部落地且实测生效 |
