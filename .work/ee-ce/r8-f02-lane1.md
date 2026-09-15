# R8 F02 复审报告 — lane1（终局收敛轮，2026-09-14）

## 结论

**PASS**

集成测试 80+ 断言全部分界正确；R7 修复（`dlg/Field/Permissions.vue` visible watch `immediate:true`）无回归，纯后端路径验证通过；全 diff 代码复审无 error。以下 2 条非 F02 缺陷的观察已实测归因，不计 error：

- `[观察-上游] packages/nocodb/src/db/BaseModelSqlv2.ts:6013`：v1 bulkUpsert 带 Id（update 分支）在权限放行后 500（`afterUpdate(prevData[0],...)` prevData 为 undefined）。pre-F02（4b26d7a23f^）同调用与实现逐字一致，且 owner 无 grant 同样 500 → 上游 CE 既有缺陷，非 F02 引入。建议另行登记上游 issue。
- `[观察-测试法]` 初测 E6（user grant + enforce_for_form=false + 匿名 form 提交）我方期望 403 实得 200，经核对为**期望笔误**：前端 `usePermissions.isAllowed` 与后端 `checkPermission` 同序——`enforce_for_form===false` 先放行，匿名硬拒（tableFieldPermission.ts:37）仅作用于 enforce=true；补测 user grant enforce=true 匿名提交 = 403 PASS。前后端语义一致，非缺陷。

## R7 修复验证（重点，A 段 4/4）

| # | 断言 | 结果 |
|---|---|---|
| A1 | POST nobody grant（Restricted 列）→ 200 | PASS |
| A2 | 重复 POST 同 (entity,entity_id,permission) nobody → 400 重复拒绝 | PASS |
| A3 | PATCH 同一 grant 至 nobody（R7 修复后前端 Save 走的路径）→ 200 | PASS |
| A4 | DELETE grant 后 editor 下一请求 PATCH Restricted → 200（fail-open 即时恢复） | PASS |

代码面：`watch(() => props.visible, ..., { immediate: true })` 仅在「挂载即 visible=true」（Content.vue Details tab 路径：`openField` 先置 activeField 再置 visible → v-if 挂载时 immediate 恰好执行一次 loadCurrentGrant）补齐加载；ColumnMenu 路径（false→true 翻转）行为不变。`save()` 依 existingId 分 PATCH/POST → A2/A3 证明不再撞重复 400。无副作用面。

## 全矩阵（grants × roles × 9 写路径）

每 grant 下 editor/creator 各跑 9 路径（PATCH v2 / PATCH Normal-only 对照 / INSERT v2 / bulkInsert v2 / bulkUpdate v2 / bulkUpdateAll v1 / bulkUpsert v1 / INSERT v1 / PATCH v1 updateByPk），owner 抽测：

- **nobody**：editor/creator 全路径 403（9/9×2），Normal-only 更新 200（受限列外不受影响），owner PATCH/INSERT 200 — 20/20 PASS
- **role:editor**：editor 200 全路径、creator 200 — PASS（bulkUpsert 2 例见[观察-上游]，403 会先抛故拦截语义已被 nobody 段证明）
- **role:creator**：editor 全路径 403、creator 200 — PASS
- **user:[editorId]**：editor 200、creator 全路径 403 — PASS
- **upsert 补充**（insert 分支，无 Id）：无 grant 201 / nobody 403 / role:editor editor 201 creator 201 — 权限挂点分界正确

## fail-open（C 段）

删全部 grant → editor PATCH Restricted 200；grants 列表空校验 0；A4 grant delete 后下一请求即放行。无 grant 全路径 200 在矩阵前基线亦验证。

## 校验对称（D 段 19/19 + ACL 4/4）

create 侧：nobody+subjects / user 缺 subjects / role 缺 granted_role / role=viewer 低于 minimumRole(EDITOR) / granted_role 非法枚举 / granted_type 非法 / entity=table 拒绝 / field+TABLE_RECORD_ADD 拒绝 / entity_id 不存在 → 全 400。
update 侧：nobody+subjects / user 缺 subjects（无既有） / granted_role=null / viewer / bogus / bogus granted_type → 全 400；role→nobody 200 且 granted_role 落 null；nobody→user+subjects 200；user grant 不重发 subjects（保留）→ 200。
ACL：editor POST/PATCH/DELETE → 403（creator+ 配置）；editor GET → 200（editors+ 可读）。

## 公共表单（E 段）

form view 共享后匿名提交：无 grant 200 / nobody(默认 enforce=true) 403 / PATCH enforce_for_form=false → 200 / user grant enforce=true 匿名 403（硬拒路径）/ 删 grant 后 200。前后端语义对称（见[观察-测试法]）。

## 回归与静态门

- F05 `GET bases/:id/variables` 200；F07 `GET snapshots` 200；F08 base meta 200；F10 `GET dashboards` 200；owner 数据写 200
- `tsc --noEmit`：0 error
- jest：**26/26**（2 suites）
- DB（nocodb-dev）：测试 base 权限行 0 残留、orphan subjects 0、nobody×subjects 0、CE 预建索引（context/entity）在

## 代码复审（4b26d7a23f^..ca6c81f5a6 全 diff，21 文件 +1625/−53）

- **fieldPermissionEntityIds**：Set 去重、三键（column_name/title/id）、system+pk+FK+isSystemColumn 四重过滤、空 payload → []；R6 全收集（find-first 改全匹配，over-block 为安全向）✓
- **checkPermission**：owner 直通 → req 级 permissions（预载优先，缺省 Permission.list）→ 空 list fail-open；多 grant 全评估任一 deny 即 403（顺序无关）；匿名分支 every(enforce_for_form===false) 放行语义与前端同序对称；错误消息只含字段 title 无内部泄漏 ✓
- **Permission.update**：resolved-type 三守卫（nobody+subjects / role 缺 role 含 explicit-null 语义 / user 缺 subjects 含既有回退）先于任何写；subjects 全删重建；nobody 兜底二次清 subjects（payload 顺序无关）——D17 DB 级零残留实证 ✓
- **validateGrantShape**：enum/minimumRole/subjects 形状/nobody+subjects 共享于 create+update；update 侧 'granted_role' in data 的 key-presence 语义（explicit null 不被 ?? 吞）✓
- **挂点覆盖**：insert.ts 单条+bulk（bulk 尊重 skipPermissionCheck）、v1/public-form 汇聚点（isPublicForm 仅 public-datas 标记）、updateByPk、bulkUpsert（raw 跳过）、bulkUpdate（raw 跳过）、bulkUpdateAll（skipValidationAndHooks 跳过）、updateLTARCols ✓
- **杂项**：controller v1/v2 双路径 + @Acl 四 op 注册 noco.module ✓；Base.delete/softDelete 清理权限行 ✓；探针/console.log 零残留；role grant 附带 subjects 为惰性行（SDK evaluatePermission role 分支忽略 subjects，无行为/安全影响，前端 save() 亦不发）——不构成 error
- **性能**：写路径 +1 次索引化 meta 查询（R1 deliberate cache-free，注释已载明裁决理由）；grant 通常为 0 行时即 1 次 SELECT，量级可接受

测试脚本与中间产物：`.work/ee-ce/r8-lane1-env.sh`、`.work/ee-ce/r8-lane1-matrix.sh`、`.work/ee-ce/r8-lane1-valid.sh`。
