# r3-f02-lane2 — F02 Edit field permissions R3 复审（收敛第 2 轮）

审查对象：4b26d7a23f（实现）+ e85a421d92（R1 修复）+ 3b9dcbdbc6（R2 修复）。
方法：R2 diff 逐项验证 + 静态走查（update targetType/subjects 组合、validateGrantShape requireSubjectsForUser 路径）+ dev server 实测矩阵（nocodb-dev，测试前缀 f02r3l2-*，owner=super，editor/e2/u2/commenter/viewer/c1(creator) 七号）。

## 结论

issues：

1. `packages/nocodb/src/models/Permission.ts:368-394` : update() 的 nobody-清-subjects 清理在 `if (data.subjects)` 重建块**之前**执行，PATCH `{granted_type:"nobody", subjects:[...]}` 组合时 subjects 被重建，R2「nobody 清 subjects」修复被绕过 : resolved type 为 nobody 时拒绝 subjects 载荷，或把 subjects 清理移到重建块之后统一收口

   实测绕过链（owner 令牌，granted 字段 Secret=c3f0g2x3f6y4bae）：
   - PATCH nobody+subjects=[editor] → 200，GET permissions 显示 `gt=nobody subjects=[{editor}]`，DB `nc_permission_subjects` 1 行
   - 接着 PATCH `{granted_type:"user"}`（不带 subjects）→ 200，subjects 保留 = **R2 修复声称要堵的「stale subjects 静默恢复访问」场景完整复现**
   - 正常路径（PATCH 只带 nobody）修复有效：DB subjects=0、granted_role=NULL

## R2 五项修复验证

| R2 项 | 结果 | 证据 |
|---|---|---|
| 探针清理 [F02-Q/R/P/Z] | ✓ | grep Permission.ts/permissions.service.ts/permissions.controller.ts/usePermissions.ts/Field/Permissions.vue 无 console.log / F02-* 残留 |
| PATCH granted_role 走 validateGrantShape | ✓ | PATCH viewer/commenter→400 `below the minimum role`；bogusr→400 `Invalid granted_role`；creator→200 |
| nobody 清 subjects | ✓ 正常路径 / ✗ 组合路径 | 见 issue 1；正常路径 DB subjects=0 + granted_role NULL |
| datas.service view-submit 去 isPublicForm | ✓ | diff 确认移除；public-datas.service:825 匿名共享表单路径保留标记，语义自洽 |
| acl permissionList editor+ | ✓ | 矩阵 4 |
| FE loadPermissions(force) | ✓ | diff 确认 guard 改 `!force && loadedFor===baseId` + 空(baseId)后置；save/delete/reset 均 force=true |

## 矩阵 1 — validateGrantShape（create / update）

| 用例 | create | update(PATCH) |
|---|---|---|
| role+editor | 200 | 200 |
| role+viewer | 400 `below the minimum role` | 400 同左 |
| role+commenter | 400 同左 | 400 同左 |
| role+bogusr | 400 `Invalid granted_role` | 400 同左 |
| role 缺 granted_role | 400 `granted_role is required` | —（继承 existing，已过 create 校验） |
| user+空 subjects | 400 `subjects are required` | 400 同左（role→user 转换，create/update 对称） |
| user+subjects | 200 | 200 |
| user+team subject | 400 `Team subjects are not supported yet` | —（update 同守卫，service 层） |
| nobody | 200 | 200 |
| granted_type=bogus | 400 `Invalid granted_type` | 400 |
| user 不带 subjects（现有 user grant 有 subjects） | — | **200 且 subjects 保留**（实测 state subjects=[editor,u2]） |

走查结论（lane 任务第 6 项）：`targetType = updateObj.granted_type ?? existing.granted_type`，user 目标时 `subjects = data.subjects ?? existing.subjects`，两者均空 → 400；`requireSubjectsForUser` 仅 create 传 —— update 显式转 user+subjects 路径实测 200 且 enforcement 生效（矩阵 3C 真实 user id 后 editor/u2 命中 200）。逻辑闭环，除 issue 1 的 nobody+subjects 组合外无洞。

## 矩阵 2 — 生命周期（granted 字段 Secret，v2 API + DB 直查）

- create(nobody) → update(user+subjects) → update(nobody)：DB `nc_permission_subjects` count=**0**，granted_role=**NULL** ✓
- update(user) 不带 subjects → 200，subjects 保留 ✓
- delete grant → DB subjects 残留 0、nc_permissions 行 0 ✓
- PATCH nobody+subjects → subjects 落库 ✗（issue 1）

## 矩阵 3 — enforcement（PATCH /api/v2/tables/:tid/records，v2 平铺 body）

| grant | editor | e2(另一editor) | u2 | c1(creator) | commenter | viewer | owner |
|---|---|---|---|---|---|---|---|
| role=editor | 200 | 200 | — | 200 | 403 | 403 | 200 |
| role=creator | 403 | — | — | 200 | — | — | 200 |
| user subjects=[editor,u2]（真实 user id） | **200** | 403 | **200** | 403 | 403 | — | 200 |
| nobody | 403 | 403 | — | 403 | — | — | 200 |

- insert 路径（POST /records）：nobody 下 editor 403 / owner 200 ✓
- 非 grant 列不受累：nobody 下 editor 只 PATCH Title → 200 ✓
- 删 grant 后 fail-open：editor PATCH Secret → 200 ✓
- 注：首轮 user-grant 命中者 403 系测试误用 email 作 subject id；FE 弹窗发 `u.id`（nanoid，dlg/Field/Permissions.vue:58 loadMembers），改真实 id 后全对。**服务端不校验 subject id 存在性**——配错 id = 该字段 deny-all，属配置错误语义（EE 同），观察项非 error。

## 矩阵 4 — permissionList ACL（R2 editor+ 开放）

- 本 base：editor/e2/c1/owner → 200；commenter/viewer → 403 ✓
- 跨 base（editor 所属 base A list base B）：editor/c1/commenter → 403；owner → 200 ✓（无跨 base 泄漏）
- permissionCreate/Update/Delete 保持 creator+：editor create/patch/delete → 全 403；creator → 200/200/200 ✓

## 矩阵 5 — 即时性（无重启/无缓存迟滞）

- create nobody → 下一请求 editor v2 写 403、**v1 写（PATCH /api/v1/db/data/v1/:bid/:tid/1）403** ✓
- PATCH → role=editor → 下一请求 editor v2 写 200 ✓
- delete grant → 下一请求 editor v2 写 200 ✓
- 重建 nobody → v1 写 403；再删 → v1 写 200 ✓（v1+v2 双路径均即时）

## 静态复审补充（非 error 观察项）

- user grant 转换后残留旧 granted_role（PATCH user+subjects 后 gr=creator）——评估路径不消费（evaluatePermission user 分支只看 subjects），惰性数据无行为影响。
- role grant 上 PATCH 带 subjects 会存 subjects 行（惰性，role 分支不消费）——同上。
- update() 前置的 validateGrantShape（subjects: data.subjects）与后续 user-subject 双重校验并存，逻辑冗余但语义一致。
- checkPermission 请求级 list 经 req.context（BaseModelSqlv2 实例缓存首请求 context 的坑已在代码注释标明处理）；矩阵 5 即时性实测间接证实无跨请求陈旧。

## E3

无。测试中沙箱间歇报 `failed to change group ID`（zsh 复合命令，工具侧），改 python 脚本绕过，与被测代码无关。

测试残留清理：grant/base B 已删；tmp-l2 下 token 文件已删（enf.py/enf2.py/acl_imm.py 留作证据）；测试账号 f02r3l2-*（7 号）与 base「F02R3L2 base」留在 nocodb-dev 供其它 lane 复核。
