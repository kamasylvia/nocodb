# R8 F02 复审报告 — lane3(终局收敛轮)

**结论:PASS**(0 error;2 条非 F02 的 pre-existing 观察项,见文末)

审查对象:4b26d7a23f(实现)+ e85a421d92/3b9dcbdbc6/a8fc2c2966/b95fbf7f74/10e8d92729(R1-R5)+ 0711660b8c(R6)+ ca6c81f5a6(R7),`git diff 4b26d7a23f^..HEAD` 全量。
环境:http://localhost:8080 dev server(nocodb-dev,未重启);psql 仅 nocodb-dev。

## 1. 代码复审(整个 diff)

| 项 | 结果 | 证据 |
|---|---|---|
| fieldPermissionEntityIds 全收集 | ✓ | BaseModelSqlv2.ts:10535+ Set 去重;匹配 column_name/title/id 三键;过滤 system/pk/ForeignKey/isSystemColumn |
| checkPermission 任一拒绝即 403 | ✓ | BaseModelSqlv2.ts:10570+;逐 grant 评估 `denied` 短路;owner 直通(getProjectRole);无 grant fail-open;req 级 permissions 复用 |
| update() resolved-type 三守卫 | ✓ | Permission.ts update():validateGrantShape → granted_type 枚举 → nobody/user/role 各自不变量;全部在任何写之前;nobody 先清 granted_role、subjects 重建后再清 subjects(顺序无关) |
| validateGrantShape 共享校验 | ✓ | create 强制 requireSubjectsForUser;create/update 共用 enum/minimumRole/subjects 形状/nobody+subjects 拒绝;R4 显式 null/'' granted_role 不被 ?? 吞掉 |
| 探针/console.log 残留 | ✓ | diff 新增行 grep console./debugger = 0(现存 console 均为上游遗留行) |
| 错误消息不泄漏 | ✓ | 403 仅含字段 title(受限制角色本就可读该字段,无增量泄漏);404/400 消息无内部细节 |
| skipPermissionCheck 尊重 | ✓ | insert.ts:345 bulk 路径受 `!skipPermissionCheck` 门控;import.service 2494/2536/2603 传 true(复制/快照/导入走 importModelsData→bulkInsert,免自拦) |
| base 清理 | ✓ | Base.delete 与 softDelete 均调 Permission.deleteByBaseId |
| ACL | ✓ | permissionList=editor+(R2,读面供 lock 图标);create/update/delete=creator+(base scope);controller 注册 noco.module.ts |

R7 修复相关性确认:dlg/Field/Permissions.vue 的 `watch(() => props.visible, ..., { immediate: true })` 在位(ca6c81f5a6);loadCurrentGrant 现读 permissions、save 复用 existingId——回显与重复 POST 缺口代码级闭合。

## 2. 集成测试(live,nocodb-dev)

对象:新 base pv1da7li71zgjp0(F02R8L3),Sheet1(Title/Secret/sec_x_col/decoy_col/Lnk)+ Refs;owner(psql 提权 super)/creator/editor 三号。

### 2.1 全矩阵拦截/放行(共 ~50 断言,全过)

- **nobody grant**:editor/creator 在 v2 PATCH、v2 insert(带字段)、v2 bulkInsert、v2 bulkUpdate、v1 insert、v1 update、v1 bulkInsert、v1 bulkUpdateAll、v1 bulkUpsert → 全 403;owner → 200;不带受限字段写 → 200(只查写入列)。
- **role grant**:editor(=editor)→ editor/creator 200;creator(=creator)→ editor 403 / creator 200。
- **user grant**:subjects=[editor] → editor 200 / creator 403 / owner 200。
- **multi-grant 顺序无关**(DB 直插第二条 role-creator):editor 与 creator 双双被任一不匹配 grant 拒绝(403),owner 通过;删除后恢复。
- **v1 别名路由**: tableName 位置用表 id(该 base 的 title 解析 404 为上游 alias 既有行为,与 F02 无关,7 条 v1 路径均已覆盖)。

### 2.2 fail-open / 生命周期

- 0 grant 时全部写路径 200(editor/creator)。
- grant API DELETE → 下一请求即放行(v2 PATCH、v1 bulkUpdateAll、匿名表单均验证)。

### 2.3 校验对称(全 400)

create:entity=table(暂不支持)、field+错误 key、nobody+subjects、user 无 subjects、granted_role 非法枚举、viewer/commenter 低于 minimumRole、role 缺 granted_role、entity_id 不存在、坏 subject 形状、team subject、重复 grant → 11/11。
update:nobody+subjects、granted_role=null、granted_role=''、role→user 无 subjects(无留存)→ 4/4;user→user 不带 subjects(留存 subjects)→ 200;nobody→清 granted_role 与 subjects(库验证 0 行)→ ✓。
ACL:editor permissionList 200;editor create/update/delete 403。
跨 base entity_id → 400 "Column not found"(Column.get 实际按 base 域校验,无脏行通道)。

### 2.4 link 路径

受限 link 列(nobody)→ relationDataAdd editor/creator 403、owner 200;grant 只在 Secret 时 link 操作不受牵连 200。

### 2.5 R6 title/column_name 碰撞

decoy 列 title == 受限列 column_name:editor 以该键 PATCH → 403(全收集过阻断,安全方向过阻断);decoy 自身键 → 200(不误伤)。

### 2.6 公共表单(API 建 form view + POST share)

nobody+enforce_for_form=true → 匿名提交 403(且数据确实未写入);false → 200 且值落库;恢复 true → 403;grant 删除 → 200 fail-open。isPublicForm 标记 + checkPermission 的 per-grant enforce_for_form skip 匿名与表单两分支均正确。

### 2.7 回归 + 静态

- F05:variables create(key=R8VAR)+ list 200 ✓
- F07:snapshots list 200 ✓
- F08:base meta get 200、含 is_private ✓
- F10:dashboards create+list 200 ✓
- `tsc --noEmit`:0 错误(exit 0)
- jest:2 suites / **26/26** passed

## 3. 观察项(非 error,不计违反)

1. **v1 bulk upsert allow 路径 500(pre-existing,非 F02)**:`POST /api/v1/db/data/bulk/noco/:baseId/:tableId/upsert` 在允许场景崩 `BaseModelSqlv2.afterUpdate (BaseModelSqlv2.ts:6013)`"Cannot read properties of undefined (reading 'Id')"。零 grant、owner 同样 500 → 与 F02 hook 无关;blame=上游 commit 5c6b198206(feat: row expansion)。F02 的 deny 路径(bulkUpsert 403)发生在崩溃点之前,不受影响。建议另开任务对上游修复。
2. permissions create 的重复检查为 check-then-insert,(entity,entity_id,permission) 无唯一索引,并发窗口可产生重复行;checkPermission 的 any-deny 使重复行仍安全(只会过拦不会漏拦)。低风险。

## 4. 判定

全部检查项 PASS;连续第 3 轮 0 error 达成条件由总裁决方按各 lane 汇总判定。

—— lane3(独立复审,未读其他 lane 报告与历史归档)
