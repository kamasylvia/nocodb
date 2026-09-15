# R4 F02 lane5 — 安全终审(收敛第 3 轮)

**结论:PASS**(0 error;4 条非 error 观察项见末节)

审查对象:4b26d7a23f(实现)+ e85a421d92(R1)+ 3b9dcbdbc6(R2)+ a8fc2c2966(R3,重点)。
方法:全量 diff 代码审 + nocodb-dev 实测 ~40 探针(测试账号 f02r4l5-owner/editor/viewer@lane5.test,base `pol8qy6nzn2fp3e`)。

---

## 1. R3 修复复检(核心)— 全过

### a. nobody+subjects 矛盾载荷 & 旁路链闭合
| 步骤 | 结果 | 证据 |
|---|---|---|
| create nobody grant(Secret=csb89sqsw9ra10c)→ `perms4rd035y2slvs1` | 200 | subjects=[] |
| editor PATCH Secret | **403** | `You don't have permission to edit the field Secret`;同请求 PATCH Title(无 grant)200 |
| PATCH `{granted_type:"nobody", subjects:[...]}` | **400** `subjects are not allowed on nobody grants` | /tmp/a1.json |
| 再 PATCH `{granted_type:"user"}`(无 subjects) | **400** `subjects are required for user grants` | /tmp/a2.json |
| DB 复核 | `subj=0`,`nobody\|NULL` | subjects 未复活,矛盾载荷未落库 |

代码闭环确认(`packages/nocodb/src/models/Permission.ts:348`):矛盾载荷 400 在**任何写之前**;`Permission.ts:409` nobody wipe 移到 subjects 重建**之后**,任意载荷顺序不变量成立。

### b. nobody→role 转换
| 步骤 | 结果 |
|---|---|
| PATCH `{granted_type:"role"}`(缺 granted_role) | **400** `granted_role is required for role grants` |
| PATCH `{granted_type:"role", granted_role:"creator"}` | **200**,行 `role\|creator` |
| 语义验证 | editor 写该字段 403(creator grant);owner 200 |

### c. user 缺 subjects(create/update)
- create `granted_type:"user"` 无 subjects → **400**(Permission.ts:261 requireSubjectsForUser)
- PATCH role→user 无 subjects → **400**(Permission.ts:367-374)
- PATCH user→role 无 granted_role → **400**(同 b1 路径)

## 2. 修复新面(部分更新/顺序/消息)— 全过

| 探针 | 结果 |
|---|---|
| role→nobody:PATCH `{granted_type:"nobody"}` | 200,DB `nobody\|NULL\|subj=0`(stale role 清除 + subjects wipe 均生效) |
| nobody+显式 `granted_role:"editor"` | 200 且 granted_role 被置 null(updateObj 在 `Permission.ts:378` 强制清空)——注入 role 无法借 nobody 切换存活 |
| PATCH `{granted_role:"viewer"}`(低于 RECORD_FIELD_EDIT minimumRole=EDITOR) | **400** |
| PATCH `{granted_role:"bogus-role"}`(enum 非法) | **400** |
| PATCH `{granted_type:"bogus"}` | **400** |
| PATCH `{}` 空 | 200 no-op,行不变 |
| PATCH `{subjects:[]}` on user grant | **400**(防 wipe 成 deny-all 死行) |
| PATCH `{granted_type:"nobody", subjects:[]}` | 200,subjects 保持 0(空数组≡无 subjects,一致) |
| nobody→user+subjects(editor) | 200;editor(subject)写该字段 200 |

错误消息质量:400 消息精确区分三种矛盾(不允许 subjects / 缺 granted_role / 缺 subjects);403 只含字段 title,不泄漏 column_name/内部 id。

## 3. 残余绕过面(editor + Secret=nobody grant)— 逐条结论

| 路径 | 结果 |
|---|---|
| v2 POST /records(含 Secret) | **403** |
| v2 POST /records(不含 Secret) | 200(fail-open 正确) |
| v2 PATCH /records | **403** |
| v1 POST /api/v1/db/data/noco/:base/:table | **403** |
| v1 PATCH …/:rowId | **403** |
| v3 POST /api/v3/data/:base/:table/records(fields 包装) | **403** |
| v3 PATCH /records | **403** |
| bulk insert(v1 /data/bulk) | **403** |
| bulk update / bulk update-all / bulk upsert | **403 / 403 / 403** |
| link: v2 POST links/:col/records/:rowId(ChildLink=nobody) | **403** |
| unlink: v2 DELETE links/:col/records/:rowId | **403** |
| move(POST /records/:rowId/move) | N/A — `moveRecord`(BaseModelSqlv2.ts:2738)仅写 Order 系统列,不走字段值写 |
| skipPermissionCheck/raw 通道 | **不可客户端触达**:bulk-data-alias.controller 只透传 body/cookie/undo,不透传 skipPermissionCheck/raw(源码核实);仅 import.service 内部传 true |
| dataInsertByViewId(datas.service:1213) | R1 已补 param.cookie,认证用户被解析 |

## 4. fail-open / 提权 / 信息泄漏 — 全过

- **fail-open**:无 grant 时 editor 读写 200(契约保持,不会全站炸写)。
- **owner 直通**:nobody/creator grant 下 owner 写均 200(isAllowed owner shortcut)。
- **管理面 ACL**:editor GET permissions 200 / POST、PATCH、DELETE **403**(permissionCreate/Update/Delete creator+);viewer GET **403**(permissionList editor+,R2 注释与 acl.ts:559 一致)。
- **跨 base**:base1 的 grant 经 base2 路由 PATCH → **404**(metaGet2 base-scoped,无存在性泄漏;service 层 base_id 双保险)。
- **重复 grant**:同 (entity, entity_id, permission) 二次 create → **400**。
- **SDK 决策 fail-closed**:null-role grant → `rolePower >= undefined` = false(全拒,owner 除外);未知 role → false;nobody → false;`evaluatePermission` 无 fail-open 分支。
- **enforce_for_form 双态**:匿名提交含受限字段,enforce=true → 403(消息指名 Secret);PATCH `enforce_for_form:false` → 200 落库。datas.service 的 view-submit 端点不误标 isPublicForm(R1 注释与实现一致)。

## 5. 探针零残留 — 过

- `git diff 46e5c81727..HEAD` grep `console\.|debugger|f02r4l5|TODO|FIXME|XXX` = **0 命中**。
- ~40 探针 0 个 5xx(全部 200/201/400/403/404)。
- f02-tsc.log 的 3 个类型错误为 **R3 commit(07:36)前 03:15 的中间态**(行号与现文件不匹配);当前 HEAD `npx tsc --noEmit` 实测 **exit=0**。
- dev server stdout 归属启动方终端(本 lane 未持有进程),以代码 grep + 0×5xx 佐证;非 E3(证据充分)。

## 观察项(非 error,不改 PASS)

1. **role/user grant 可携带 subjects 行**(PATCH/POST `{granted_type:"role", granted_role:"editor", subjects:[...]}` → 200 且 subjects 落库)。SDK role 分支忽略 subjects → 运行时惰性;但 role→user 转换缺 subjects 时会静默携带这些先前显式提供的 subjects(w9 实测)。无提权面(subjects 本为 creator 显式提供,管理面 creator+);建议后续轮 role grant 拒绝 subjects 或 role→user 要求显式 subjects。`Permission.ts:387-405` / `insertSubjects`。
2. **resolved type 为 nobody/user 时裸 PATCH granted_role 跳过 enum/minimumRole 校验**(`validateGrantShape` 仅在 ROLE 分支校验,`Permission.ts:263`)→ 可在 nobody 行存垃圾 granted_role。运行时惰性(nobody 恒 deny;user grant 不读 role),后续 role 转换仍需过校验;纯数据卫生。
3. **公开表单 meta 仍列出受限列 fk_column_id**(`/api/v1/db/public/shared-view/:uuid/meta` 的 columns 数组含 Secret 列 id,无标题);匿名写路径已 403/可剥离。与 EE「表单无权字段隐藏」的展示面对齐建议留 F03/后续轮处理;非安全边界(列 id 本就是公开表单固有暴露面)。
4. **列删除不清理 grant 行**(columns.service 无 Permission 清理;仅 Base.delete/softDelete 走 `deleteByBaseId`)→ 孤儿行;entity_id 不再匹配,惰性无害。
5. **enforce_for_automation 列未被消费**(fork 裁定恒强制):内部无用户写路径对 granted 字段将 403,fail-closed 方向,安全无虞;功能性限制已在 fork 范围记录。

## 测试痕迹

- base:`pol8qy6nzn2fp3e`(f02r4l5-base)/ `pvfcxnu89feipfh`(f02r4l5-base2);账号 f02r4l5-{owner,editor,viewer}@lane5.test;grant 行 `perms4rd035y2slvs1`(Secret, nobody, enforce_for_form=true)、`permsi4ut5fiku9pvb`(Title, user→已删)、ChildLink nobody grant。全部 f02r4l5- 前缀,无凭证落盘。
