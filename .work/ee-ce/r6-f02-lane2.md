# F02 R6 lane2 集成测试 + 代码复审报告

- 审查对象：4b26d7a23f(实现) / e85a421d92(R1) / 3b9dcbdbc6(R2) / a8fc2c2966(R3) / b95fbf7f74(R4) / 10e8d92729(R5, 本轮重点)
- 环境：dev server :8080（nocodb-dev），base `pbukyam40b65005`，表 `mh6lznbjyu2eyre`（Name/Secret/Locked/Rels-LTAR），用户 f02r6l2-{owner(super→owner), editor, editor2, creator, viewer}
- 结论：**PASS**（0 error；2 条 E3 观察，不计 error）

## 结论行

PASS

## T1 R5 修复验证（本轮核心）

| 用例 | 结果 | 证据 |
|---|---|---|
| create nobody+subjects | 400 `subjects are not allowed on nobody grants` | T1a |
| create 干净 nobody | 200，行落库 `granted_role=null, subjects=0` | T1b + psql |
| update（存量 nobody）+subjects（不带 granted_type 键） | 400 同 msg | T1c |
| update 显式 `granted_type:nobody`+subjects | 400 同 msg | T1d |
| update 干净 nobody | 200 | T1e |
| 失败请求后 DB 残留 | subjects=0，无半写 | T1f psql |

create/update 对称性成立；拒绝收敛进共享 `validateGrantShape`（Permission.ts:265-272），update 早期守卫（:363-367）为冗余二层，msg 一致。

## T2 生命周期（每步 DB 断言）

nobody(0 subj) → update user+2subj（200，DB `user|null` subj=2）→ update nobody（200，**subjects 被清 0**，granted_role null）→ update role+creator（200，`role|creator`，subj=0）→ delete（200 `true`，perm=0 subj=0）→ 再 delete 404。全链无残留。

## T3 enforcement 矩阵（RECORD_FIELD_EDIT）

Grant 布局：Secret=role editor / Locked=user[editor2] / Name=nobody / Rels(LTAR)=nobody（临时建删）。

### PATCH 单条/数组（v2）

| 字段×用户 | editor | editor2 | creator | owner | viewer |
|---|---|---|---|---|---|
| Secret (role=editor) | 200 | 200 | 200 | 200 | 403(dataUpdate ACL 先拦, E3-2) |
| Secret (role=creator 切换后) | **403** | **403** | 200 | — | 403(ACL) |
| Locked (user=[editor2]) | **403** | 200 | **403** | 200 | — |
| Name (nobody) | **403** | **403** | **403** | 200 | — |

role=creator 切换实测证明 role grant deny 路径（editor 被拒）；owner 直通；user grant 非 subjects 全拒。

### insert / bulkInsert

- editor/creator 插入命中 grant 拒绝字段 → 403（带正确字段名 label）；仅插允许字段 → 200；bulkInsert 2 行含禁字段 → 403 且**原子**（0 行落库）；owner 全插 200。

### link API（addChild/unlink）

- editor POST link → 403 `edit the field Rels`；owner link/unlink → 201/200。

### updateLTARCols（R5 title-keyed 修复点，v3 路由实测）

- 对照：owner v3 PATCH `{id:1,fields:{Rels:[{id:2}]}}` → 200 且 links 真实改写（replace 语义）。
- editor/editor2/creator v3 PATCH Rels → **403 `edit the field Rels`**，links 不变。
- 对照组：editor v3 PATCH Secret → 200（role 允许）；editor Name → 403。证明拒绝按 grant 精确命中而非误伤。
- v3 upsert（mergeOn Secret 隔离 Rels）：editor → **403 field Rels**、editor2 → 403、links 不变；owner → 200 且 links 改写。R5 加宽匹配（column_name/title/id）在 title-keyed `linkUpdateDatas` 上实测生效。

### v1 upsert（E3-1 观察）

- v1 `/api/v1/db/data/bulk/.../upsert` 带 Rels：allowed 用户也**不写 links** —— upstream `bulkUpsert` 的 `nestedCols` 仅在 `apiVersion===V3` 非空（BaseModelSqlv2.ts:3836-3838），LTAR 键整体被忽略 → 无写入即无绕过，非 fork 引入。
- v1 upsert 命中 update 行必 500（`afterUpdate` 读 `existingRecords[0]` undefined，:4171→:6013）：git blame = upstream 作者（DarkPhoenix2704 2026-04-20 / mertmit 2026-05-15），fork 六 commit 未触该段。**F02 无责，pre-existing upstream bug**。

### 匿名表单（enforce_for_form）

- 共享 form view（uuid 01b1ef71…）匿名 `POST /api/v2/public/shared-view/:uuid/rows`：
  - Name（nobody, enforce_for_form=false）→ **200**，行 Id8 落库；
  - Name+Secret（Secret grant enforce=true）→ **403**，0 行落库（原子）；
  - Secret/Locked 单独匿名提交 → 403；还原 enforce=true 后 Name → 403。

## T4 校验对称矩阵（create/update）

| 形状 | create | update |
|---|---|---|
| role 缺 granted_role / granted_role:null / '' | 400 `granted_role is required for role grants` | 400 同（U1/U2） |
| user 缺 subjects / subjects:[] | 400 `subjects are required for user grants`（C2/C3） | 400（U3/U4/U10） |
| granted_type 越枚举 | 400 `Invalid granted_type everyone`（C4） | 400 |
| granted_role 越枚举 | 400（C5/U5） | 400（U5） |
| granted_role 低于 minimumRole（viewer<editor） | 400 `below the minimum role`（C6） | 400（U6） |
| subject 非法 type/缺 id | 400（C7） | — |
| nobody+subjects（R5） | 400（C8） | 400（U7/U11） |
| 对照：合法 role/user grant | 200（C9） | 200（U8/U9） |

全部 400 请求后 DB 无半写（psql 终态 g1=role|editor、g2=user，subjects 仅 1 行=editor2）。

## T5 代码复审

1. **validateGrantShape 拒绝顺序**（Permission.ts:243-308）：requireSubjectsForUser(create-only) → nobody+subjects → role 枚举 → minimumRole → subjects 形状。nobody 检查先于 role 分支与任务书名义顺序不同，但 granted_type 单值互斥（nobody 分支与 role 分支不可能同触），顺序无语义影响，错误消息确定。
2. **update 双层守卫一致性**：早期守卫（:363-367）与共享检查用同一 `data.subjects`、同一 msg，冗余且一致；共享检查在 update 传 `requireSubjectsForUser` 缺省（正确——update 不带 subjects 键时保留存量），resolved-target 三不变式（nobody 无 subjects / role 必有 role / user 必有 subjects）全部在任何写之前判定，R4 `'granted_role' in data` 存在性语义未被 R5 改动破坏（U1/U2 实测）。
3. **immutable 字段**：update `extractProps` 白名单不含 entity/entity_id/permission → 不可漂移；service 层校验 base 归属（base_id 不匹配 400）。
4. **fail-open 契约**：空 permissions list → return；per-entity 无 grant → continue；owner 经 `getProjectRole` 直通。契约未破坏（全站无 grant 表写入实测正常）。
5. **R1 stale-context 修复**：`req.context ?? this.context`（模型实例缓存 per-model），req 级 permissions 复用保留。
6. **skipPermissionCheck 完整性**：`insert.ts` hook1（single 路径）无守卫——`single` 唯一入口是公开 `insert()`（用户面写），trusted import 三处（import.service.ts:2494/2536/2603）全走 `bulkInsert + skipPermissionCheck:true`（hook2 有守卫）→ 无误拦 trusted copy。`nestedInsert`（v1/public form）自带 hook 且带 `isFormContext`，不经 insert.ts，无双重检查。
7. **SDK 决策一致性**：`evaluatePermission` user 分支仅看 subjects（stale granted_role 惰性）、role 分支比 rolePower、nobody 落 `return false` —— 与实测矩阵完全吻合。
8. **外观级观察（非 error）**：role grant PATCH 带 subjects、user grant 残留 granted_role —— SDK 评估均忽略，惰性数据，不构成权限影响；如需整洁可后续清 stochastic 残留，不阻塞。

## E3 清单（外部/上游限制，有诊断证据，不计 error）

- **E3-1**：v1 upsert route LTAR 键被 upstream 忽略（`nestedCols` V3-gated）+ upsert-update 500 crash（`afterUpdate` upstream 代码 blame 4ee772cf42f/58ed76ab443）。诊断：allowed 用户 upsert Rels 不写 links（BaseModelSqlv2.ts:3836）；crash stack `afterUpdate←bulkUpsert:4171`。影响：F02 无 bypass（无写发生）；upstream bug 待上游修复。
- **E3-2**：viewer 的字段级 deny 不可观测 —— CE `dataUpdate` ACL 在字段检查前 403（`Forbidden - You do not have permission to update data`）。属 CE 角色模型（viewer 本就不可写记录），非 F02 缺陷；sub-editor deny 由 role=creator 实测覆盖。

## 证据留存

- 测试产物：`/tmp/f02r6l2/`（tokens/base-id/grant-ids/响应样本，一次性 dev 账号口令仅存本地）
- 测试数据：nocodb-dev `pbukyam40b65005`（f02r6l2-* 前缀用户/base/表/grant 行留存可复核）
- 会话期间 8080 曾短暂 000（rspack 重编译窗口），等待后自愈，非代码问题。
