# r4-f02-lane2 — F02 Edit field permissions R4 轮复审(集成测试 + 代码复审)

对象:4b26d7a23f(实现)+ e85a421d92(R1)+ 3b9dcbdbc6(R2)+ **a8fc2c2966(R3,本轮重点)**。
环境:dev server :8080(nocodb-dev),测试 base `pp7owme2kr92xas`(f02r4l2-base),表 `m67s04c8u9t3h6j`,账号 f02r4l2-{owner,editor,creator,commenter,viewer}@test.local。

## 结论

issues 列表(3 条,均实测复现):

1. `packages/nocodb/src/models/Permission.ts:354-365`:role 行 PATCH `{granted_role:null}` 返回 200 且落库 `granted_role=NULL`,复现 R3 commit 明言封死的 null-role deny-all 坏态。根因:守卫条件 `!((data.granted_role ?? (existing).granted_role))` 用 `??` 把 null 回落到 existing 非空值,且整条守卫被 `updateObj.granted_type === ROLE` 限定为只在显式切 type 时触发;而 `extractProps`(nocodb-sdk commonUtils.ts:19,`body[key] !== undefined`)会提取 null 写库。建议:resolved role 改用「键存在即取 data 值(不回落 null)」——`const resolvedRole = data.granted_role !== undefined ? data.granted_role : (existing as Permission).granted_role;`,并在 `targetType===ROLE && resolvedRole 无效(null/空串)` 时 400,不限 `updateObj.granted_type`。
2. `packages/nocodb/src/models/Permission.ts:354-365`(同位置,空串变体):role 行 PATCH `{granted_role:""}` 返回 200 且落库 `granted_role=''`。validateGrantShape role 分支对 falsy granted_role 直接跳过(enum/minimumRole 不校验),守卫 2 又只对显式 granted_type 切换触发,双重漏过。建议:同上按 resolved 值校验;validateGrantShape 的 role 分支把「`grant.granted_role` 为空串」显式 400(当前仅 undefined/null 静默跳过)。
3. `packages/nocodb/src/services/permissions.service.ts:123-128`:update 通道 team subject 拒绝条件 `body.granted_type === USER` 过窄——user 行 PATCH `{subjects:[{type:"team",id:"team_x"}]}`(不带 granted_type)返回 200,team subject 落库,绕过 create 通道的 "Team subjects are not supported yet" 显式拒绝;后端 isAllowed 无 matchedTeamSubject,team subject 永不命中 → 该 user grant 静默退化为 deny-all(除 owner),与 R2 封「user grant 无 subjects 静默拒全员」的动机同类。建议:update 里当 `body.granted_type === USER || ((existing).granted_type === USER && body.subjects)` 时对 body.subjects 拒 team。

严重度:三条均为 deny 方向(不提权、无越权数据访问),但 1/2 使 R3 建立的「resolved-type 三不变量」在 role→role 路径仍可被 API 直调绕过,3 与 create 规则不一致并落地静默 deny-all。UI 正常路径不受影响(前端 PATCH 均显式带 granted_type)。

## R3 修复核心验证(任务项 1)——全部通过

| # | 操作 | 期望 | 实测 | DB 断言 |
|---|---|---|---|---|
| 1.1 | POST create nobody | 200 | 200 | `nobody\|- \|0` |
| 1.2 | PATCH `{nobody, subjects:[editor]}` | 400 | 400 `subjects are not allowed on nobody grants` | `nobody\|- \|0`(未插回) |
| 1.3 | PATCH `{granted_type:"user"}` 不带 subjects | 400 | 400 `subjects are required for user grants` | `nobody\|- \|0`(旁路链闭合) |
| 1.4 | PATCH `{granted_type:"role"}` 无 granted_role | 400 | 400 `granted_role is required for role grants` | `nobody\|- \|0` |
| 1.5 | PATCH `{role, creator}` | 200 | 200 | `role\|creator\|0` |
| 1.6 | PATCH `{nobody, subjects:[]}` | 200 | 200 | `nobody\|- \|0` |
| 1.7 | PATCH `{}` 空载荷 | 200 no-op | 200 | 状态不变 |

R3 lane2 报的 nobody+subjects 旁路:已闭合(1.2 写前 400 + 1.3 转换守卫,双闸)。

## 全生命周期(任务项 2,Amount 列)——通过

nobody → user+[editor] → nobody → role+editor → user+[editor],每步 DB 断言:

| 步 | 转换后 DB | subjects | editor 下一请求(即时性) |
|---|---|---|---|
| 0 nobody | `nobody\|-\|0` | 0 | PATCH 字段 403 |
| 1 → user+[editor] | `user\|-\|1` | 1 | 200 |
| 2 → nobody | `nobody\|-\|0`(subjects 被清) | 0 | 403 |
| 3 → role+editor | `role\|editor\|0` | 0 | 200 |
| 4 → user+[editor] | `user\|editor\|1` | 1 | 200 |
| 5 DELETE | grants=0 | — | — |

每步转换下一请求即时生效,无缓存滞后(Permission.list 刻意 cache-free 生效)。观察项(非 error):step4 role→user 后 `granted_role=editor` 残留在 user 行——SDK evaluatePermission 对 user grant 忽略 granted_role,无功能影响;仅切 nobody 时清 role,切 user 不清,轻微不对称。

## 角色矩阵(任务项 3,Secret 列;403 为拒)——通过

| grant 配置 | editor | creator | commenter | viewer | owner |
|---|---|---|---|---|---|
| baseline(无 grant,fail-open) | 200 | 200 | 403* | 403* | 200 |
| role=editor | 200 | 200 | 403* | 403* | 200 |
| role=creator | 403 | 200 | 403* | 403* | 200 |
| user=[editor] | 200 | 403 | 403* | 403* | 200 |
| user=[ghost id] | 403 | 403 | 403* | 403* | 200 |
| nobody | 403 | 403 | 403* | 403* | 200 |

\* commenter/viewer 的 403 含 base 角色 ACL 背景拒(无 grant 时同为 403),非 grant 证据;editor/creator 格为有效判据。owner 全格 200(owner 直通)。user grant 命中(editor 命中 200)/未命中(ghost/creator 对 [editor] 403)均正确;multiple-grant most-restrictive 语义在 checkPermission(BaseModelSqlv2.ts:10634-10649 any-denial-blocks)代码层确认。

## permissionList ACL + CUD(任务项 4)——通过

- GET list:owner 200 / creator 200 / **editor 200**(R2 editor+ 读域,驱动前端 lock 图标)/ commenter 403 / viewer 403
- 跨 base 隔离:editor GET 异 base permissions → 403
- CUD:editor POST/PATCH/DELETE 全 403;creator POST 200 / PATCH 200 / DELETE 200(creator+ 写域)

## 边界补充(T7,全过)

create user 无 subjects 400 / duplicate (entity,entity_id,permission) 400(R1 仍在)/ nobody 行 PATCH `{nobody, granted_role:"creator"}` → 200 且 `granted_role=NULL`(updateObj nobody 分支清 role,生效)/ create team subject 400 / v1+v2 双路径(GET、PATCH 均通)/ granted_role 非法枚举 400 / 低于 minimumRole(viewer < editor)400 / PATCH 未知 permissionId 404 / PATCH `{entity:"table"}` 不可变(extractProps 不提取,行不变)/ PATCH `enforce_for_form:false` 200 生效 / subjects 缺 id 400。

## 代码复审(任务项 6)

update() 全流顺序符合任务书描述:`get → validateGrantShape(R2 形状)→ extractProps → granted_type enum → 三守卫(R3 写前)→ metaUpdate(nobody 时清 granted_role)→ subjects 重建(delete+insert,仅 data.subjects 键存在时)→ nobody subjects 清理(重建后)→ get`。三守卫对「nobody+subjects」「nobody→role 缺 role」「→user 缺 subjects」的写前校验正确,唯独 role→role 的 granted_role 键级更新绕过守卫(见 issues 1/2)。validateGrantShape 的 `requireSubjectsForUser` 选项:insert 传 true、update 不传(update 内自行以「data.subjects ?? existing.subjects」判定),分工正确。

观察项(非 error,不计):update 路径 metaUpdate 与 subjects 重建无事务包裹,极端中断可致 user grant 空 subjects(deny 方向);subjects 不校验目标 user 存在性(ghost id 落库,deny 方向安全)。

## E3 / 外部限制

无。

## 资产

测试脚本:`.work/ee-ce/f02r4l2-t1.sh`、`f02r4l2-t2.sh`、`f02r4l2-t34.sh`、`f02r4l2-t3b.sh`、`f02r4l2-t6.sh`、`f02r4l2-t7.sh`、`f02r4l2-dbq.sh`(凭证文件 `.f02r4l2-dbenv`/`.f02r4l2-tokens` 已删)。测试 base `pp7owme2kr92xas` 保留(grants 已清零)。
