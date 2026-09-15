# F03 Data permissions — R3 lane4 复审报告(功能全量集成 + 全 diff 复审 + UI)

**结论:PASS — 0 error。2 项建议级观察 + 1 项 E3(环境),均不阻断收敛。**

审查对象:7b10716231 + 2f5a57b0d3 / e1e996283c / 0a3e5fdab4 / c7a242cdf3 / 6cc43e0b81(HEAD = 6cc43e0b81)。
测试资产:`.work/ee-ce/r3-lane4/`(env.sh + t1-t4 脚本;base=F03R3-Matrix `piq8uix5c455n7b`,Tasks=`mpsnq8mna3o6okd`,三账号 owner/editor/creator)。

---

## 1. 代码复审(整个 diff,F02+F03 触碰面)

| 项 | 结果 |
|---|---|
| `fieldPermissionEntityIds` 全收集(R6) | ✓ Set 去重、column_name/title/id 三键全命中即收、system/pk/FK/isSystemColumn 过滤;over-block 语义安全 |
| `checkPermission` any-deny(R1) | ✓ 多 grant 全评估任一拒即 403,顺序无关;owner 直通;空清单 fail-open 短路;匿名+grant fail-closed,form 上下文按 `enforce_for_form`(every 全豁免才过);context 挂 req(R1 缓存修复)正确 |
| `Permission.update()` resolved-type 三守卫(R3/R4/R5) | ✓ NOBODY+subjects 拒 / ROLE 缺 role 拒(显式 null 不被 `??` 吞)/ USER 缺 subjects 拒,均在写前校验;subjects 重建(删全+重插)后 NOBODY 再清一次兜底 |
| `validateGrantShape` 共享(R2) | ✓ granted_role 枚举 + minimumRole(TBL_VIS=viewer/ADD/DELETE=editor)+ subjects 形状 + nobody+subjects 互斥;create/update 同源 |
| `permissions.service` TABLE 解封 | ✓ 3-key 白名单、Model 存在 + base 归属 + synced 拒配、(entity,entity_id,permission) 重键拒、team subject 双路(create + update resolved-type)拒 |
| extract-ids VISIBILITY gate(R2) | ✓ 主路径 ncTableId 赋值 + v1 `:tableName` fallback(c7a242cdf3);404 非 403;`isServiceUser` 豁免;`permissions.length` 短路;匿名由 helper 回落 default |
| 失实注释 | ✓ data-table.service.ts:398 已改 |
| 探针残留 | ✓ diff 全量 grep 零 console.*/debugger/FIXME |
| tsc / jest | ✓ `tsc --noEmit` 0 错;Fork.spec 26/26 |

## 2. 集成测试(全矩阵,via nocodb-dev @8080)

### 2.1 权限矩阵(31/31 OK,t2_matrix.sh)
- **ADD**:nobody→editor/creator 单条+bulk+upsert 含插入行全 403,owner 200;ADD 不拦 update/delete ✓;role:creator→editor 403/creator 200;role:editor→editor 200;user:[creator]→creator 200/editor 403。
- **DELETE**:nobody→editor v2 单删/v1 delByPk/v1 bulkAll 全 403,insert/update 200,owner 200;role:creator→editor 403/creator 200。
- **VISIBILITY**:nobody→editor+creator meta 404、v2 data GET/POST 404、v1 data 404、表列表隐藏(0 命中)、owner 200;role:viewer→全员 200;user:[creator]→creator 200/editor 404。
- **fail-open**:v1/v2 全路径无 grant 全 200(t1);删 grant 后下一请求放行(J)✓。
- **批量面**:v2 bulk insert/bulkUpsert(纯 update 批不要求 ADD ✓)、v1 bulk/datalist、v1 deleteAll(where)。

### 2.2 校验对称(20/20 实质过,t3;K10/L12 首报 FAIL 为脚本断言多行比较伪影,复测通过)
- create:nobody+subjects / role 缺 granted_role / user 缺 subjects / 非法 granted_type / 非法 granted_role / viewer<minimumRole(ADD) / field×table-key / table×field-key / 不存在表 / 重复键 → 全 400。
- update:nobody+subjects / 非法 type / null role / 低于 minimumRole / 切 user 无 subjects / user grant+team subjects(无 granted_type,R4 resolved-type)→ 全 400;合法迁移 nobody↔role↔user 全 200。
- ACL:editor create/delete 403、editor list 200、creator create 200、匿名 401。

### 2.3 VISIBILITY 深场景
- link 无泄漏:editor 经 Other 行 mm link 读隐藏 Tasks,嵌套/直连两形态均只回 pk+pv(Id/Name),Secret 不出现。
- 匿名 shared form(直插 nc_views_v2 form view + 8080 直连):baseline POST 200;ADD nobody + enforce_for_form=true → 匿名提交 **403**;PATCH enforce_for_form=false → **200**;VISIBILITY nobody → 匿名 rows **404**、删 grant 恢复。

### 2.4 回归(全绿)
- F02 交互 4/4:Secret RECORD_FIELD_EDIT nobody → editor PATCH 该字段 403 / 不含该字段 insert 200 / 带该字段 insert 403 / 删 grant 恢复 200。
- F05 变量 create+list 200;F07 快照 create 200 + 状态 completed;F10 dashboards list 200;非协作者 base meta/tables/data 403/403/403。

## 3. UI 段(camoufox-cli,owner 会话完整走查)

- 截图 1 `.work/ee-ce/r3-lane4/ui1-owner-permissions-tab.png`:Details → Permissions tab,三 key 摘要与 API 状态一致(ADD=Creators & up / Visibility=Viewers and up / Secret 字段=Nobody)。
- 截图 2 `.work/ee-ce/r3-lane4/ui2-owner-permissions-dialog.png`:Configure 弹窗渲染三组单选(ADD: Creators&up/Editors&up/Nobody;DELETE 同;VISIBILITY: Viewers/Everyone/Nobody)+ Reset/Cancel/Save。
- UI→API 往返:弹窗把 ADD 从 Creators & up 切回 Editors & up 保存 → API 侧 TABLE_RECORD_ADD grant 被删除(默认=删行语义 ✓);无错误 toast、无 Nuxt error overlay。
- console error / 5xx 双零:owner 会话 overlay=false + toast 空;API 面全部断言 200/400/403/404,零 500(v1 DELETE rowId=0 的 500 为上游既有行为,非 UI 触发、非 F03 面)。

## 4. 观察项(非 error,建议级)

1. `packages/nc-gui/composables/usePermissions.ts:118 getPermissionSummary`:无 grant 时 TABLE_RECORD_ADD/DELETE 显示 "Everyone"。操作语义等效(viewer/commenter 本无写权,角色 ACL 保底),但与上游默认文案 "Editors & up" 不一致。建议:非 VISIBILITY key 无 grant 时回 EDITORS_AND_UP。
2. `packages/nocodb/src/models/Permission.ts update()`(`delete updateObj.granted_role` 处):切 NOBODY 时仅"不更新"该列,DB 残留旧 granted_role(评估不受影响——NOBODY 不读 role;导出/审计可见 stale)。注释写 "clear it" 与行为不符。建议:置 `granted_role: null` 落库或改注释。
3. shared-view meta 不在 VISIBILITY 执行面:`services/public-metas.controller.ts:13` sharedViewMeta 对 VISIBILITY nobody 仍 200(匿名可见字段名),rows/POST 已 404。上游 CE 预埋面即如此(research §2.2 未列),非 F03 引入。建议记 backlog。
4. `packages/nc-gui/components/smartsheet/grid/Table.vue:335`:computed getter 内调 `usePermissions()`——每次重算新建 composable 实例并注册 watch(loadPermissions 有 per-base guard 幂等,泄漏有界);legacy DOM 渲染器、canvas 为主,量级低。建议提升至 setup 顶层。
5. `enforce_for_form` 无弹窗开关(KeyState.enforceForForm 存在未接线;默认 true 与 EE 缺省一致)。research §7.9 建议项,fork 裁剪,记 backlog。

## 5. E3(环境,有诊断证据,不阻断)

- **:3000 Nuxt dev proxy 失效**:所有 `/api/*`(GET/POST)返回 `200 text/html`(SPA fallback 接管),8080 直连同端点 200 JSON;跨 90s/120s 三次重试复现。任务约束禁重启 server。
- 影响:editor 登录 UI 走查(截图 3:Secret 列 lock/编辑拦)无法执行;owner 段在故障发生前已完成。F03 R3 新增 UI 面即表权限 tab+弹窗(已验证);Secret lock 属 F02 已 pass 面。API 层测试全经 8080,不受影响。
- 待办:Nuxt dev 代理恢复后补 editor 会话走查一轮即可。

## 6. 测试伪影说明(非实现问题)

- 首轮矩阵 FAIL 均由测试脚本自身问题叠加造成:zsh `local` 单行多赋值展开序坑(addgr 参数丢失)、grant 泄漏叠加(delgr 空 id)、chk 参数序、路由笔误(`/api/v2/tables/:id` ≠ meta 路径)。修正后干净重跑全绿。
