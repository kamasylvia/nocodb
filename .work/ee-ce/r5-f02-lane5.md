# r5-f02-lane5 — F02 Edit field permissions R5 安全终审

**结论:PASS**（无实际违反；1 项上游遗留 bug 非 fork 引入,附诊断,建议另行上报）

审查对象:4b26d7a23f(实现)/ e85a421d92(R1)/ 3b9dcbdbc6(R2)/ a8fc2c2966(R3)/ **b95fbf7f74(R4,本轮重点)**
方法:五 commit diff + 现行源码审读,dev server(localhost:8080) API 实测,psql(qnap.elf-balance.ts.net:5432/nocodb-dev) 核值。测试前缀 f02r5l5-。

---

## 1. R4 修复复检(核心,全过)

### 1a. granted_role PATCH 显式空值/合法值 — PASS
role grant(Num 列)上实测:

| 步 | PATCH body | 结果 | psql 核值 |
|---|---|---|---|
| A | `{granted_type:'role',granted_role:'editor'}`(nobody→role) | 200 | role/editor |
| C1 | `{granted_role:null}` | **400** "granted_role is required for role grants" | 未污染(仍 creator) |
| C2 | `{granted_role:''}` | **400** | 未污染 |
| D | `{granted_role:'creator'}` | 200 | **role/creator(落库正确)** |
| E | `{granted_role:'commenter'}` | 400 "below the minimum role for RECORD_FIELD_EDIT" | — |
| F | `{granted_role:'bogus'}` | 400 "Invalid granted_role" | — |

### 1b. PATCH {granted_type:role, granted_role:null} 按 existing — PASS
- existing=role: 400(B 步)。
- existing=nobody: `{granted_type:'role',granted_role:null}`→400(J);`{granted_type:'role'}` 不带 granted_role(existing role=null 回落)→400(I)。

### 1c. user grant PATCH team subjects — PASS(R4 主目标)
- `{subjects:[{type:'team',...}]}` **不带 granted_type**(existing=user)→ **400** "Team subjects are not supported yet"(L 步,service resolved-targetType 修复生效,permissions.service.ts:123-131)。
- 显式 `{granted_type:'user',subjects:[team]}`→400(N)。
- 合法 user subjects→200,psql 核 subjects 替换正确(K/M 步)。

### 1d. form 后端兜底 — PASS
- enforce_for_form=true: 匿名 public submit(`/api/v2/public/shared-view/:uuid/rows`)带受限字段→ **403**。
- enforce_for_form=false: →200,字段接受(设计 opt-out,checkPermission isFormContext continue 分支)。
- 仅 Title 提交→200(非受限字段不受累)。
- 前端 Form.vue 门控(`element?.permissions?.isAllowedToEdit !== false`)纯渲染层,与 useSharedFormViewStore formColumns 过滤(`?? true`)语义一致;后端剥离/403 兜底独立成立。

## 2. 修复新面 — PASS(1 项非安全观察)

- **落库矩阵**:`'granted_role' in data`(键存在,显式 null 不回落 existing)× extractProps(仅排 undefined,null 保留,SRC commonUtils.ts:21)组合,与 `grantedRoleToStore`(null→'' 终值检查,Permission.ts:362-373)覆盖完整:null/''/缺省×existing 有/无 均验证(1a/1b 全步),无一例 null-role 落库。
- `PATCH {granted_type:'nobody'}`:role 列清为 NULL(H 步 psql 核值),stale role 无残留。
- **观察(非 error)**:PATCH `{granted_role:null}` on **user** grant→200,DB granted_role 仍 NULL(O 步;模型层 `null??''` 预期 '',metaUpdate/PG 侧实际 NULL)。user grant 的 granted_role 不参与 SDK 评估(evaluatePermission user 型走 subject 匹配),无安全影响,仅一致性备忘。
- **onBeforeUnmount**(dlg/Field/Permissions.vue:199-205):代码审过 — unmount 前同步 emit→父 visible=false→NcModal teleport wrap 随 visible teardown;sign-out 场景整树卸载时 emit 无害。前端层不承载安全语义(后端兜底 1d 已验)。
- `option-filter-prop="label"`:成员多选按 email/display_name 过滤,无安全语义。

## 3. 残余绕过面(editor + nobody grant,22 探针) — PASS

| 路径 | 结果 |
|---|---|
| v2 PATCH 受限字段 / v2 insert 带受限字段 | 403 / 403;Title 隔离写 200×2(仅限目标字段) |
| v1 PATCH / v1 insert | 403 / 403 |
| v1 bulk insert / bulk update / bulk updateAll | 403 / 403 / 403 |
| bulkUpsert existing 行带受限字段 | **403**(hook 先于写入生效) |
| link v1 relationDataAdd(mm) | 403 |
| link v2 nestedLink ×2 body 变体 / nestedUnlink | 403 ×3;owner control 201 落库(junction 有行) |
| v3 bulkUpdate→updateLTARCols | hook 在位(代码层,BaseModelSqlv2.ts:4721-4747) |

- v2 PATCH body 携带 nested `Link:[1]`/`{add:[1]}`:owner 实测均不落库(junction count 0)— v2 records PATCH 不处理 nested link 字段(payload 格式不支持),**不构成绕过路径**;正式 link 写走 /links 端点(hook 已验)。

## 4. fail-open / 提权 / 泄漏 — PASS

- **fail-open**:删除全部 grant 后 editor 写受限字段→200(上游契约:无 grant=允许)。
- **user grant 精确性**:grant subject=owner 时 editor 写→403,owner(subject)写→200。
- **读不误伤**:editor 读 records 始终 200(F02 只 gate 写)。
- **editor 管理面**:permissionCreate/Update/Delete→403×3(ACL creator+);permissionList→200(editor+,设计内,驱动前端 lock icon)。
- **跨 base**:editor(非成员)list/PATCH 他 base→403 "Unauthorized access"(ACL base scope);owner 用他 base permId 配错路径→404(service base_id 检查+get 记录NotFound 双防)。
- **探针零残留**:nc_permissions=0、nc_permission_subjects=0、nc_users_v2 f02r5l5*=0(测试 base 经 trash 删除,用户行已清);测试期间所有 400/403 拒绝路径无半写(psql 逐步核值)。

---

## 上游遗留(非 fork 引入,不计 error,附诊断)

**bulkUpsert 500 + 非原子更新**:`POST /api/v1/db/data/bulk/.../upsert` 对已存在行返回 500。
- 诊断:TypeError "Cannot read properties of undefined (reading 'Id')" @ BaseModelSqlv2.ts:6013(afterUpdate `oldData[k]=prevData[k]`,prevData=existingRecords[0] undefined)。
- 归因:`git blame` = 上游 commit 2681b116ac(Audit v1,mertmit 2025-01-10);F02 diff(46e5c81727..HEAD)在 bulkUpsert 区段无 hunk;owner/editor 双账号复现(与角色/权限无关)。
- 附加缺陷:500 响应但更新已落库(row1 被 owner upsert 实际改写 Title/Secret)——**响应与数据不一致**,建议另行上报上游或 fork 单独修复。

## 证据与环境

- 测试 base:p9sbqfr514chzpb(t1/t2/junction)、ps6833de0hn0c96;测试用户 f02r5l5-o/e-1789346223@t.io(已清)。
- 全部 47+ 探针步骤、请求体、响应码、psql 核值见本文各表;R4 五项修复目标(1a/1b/1c/1d/键存在语义)全部实测通过。
