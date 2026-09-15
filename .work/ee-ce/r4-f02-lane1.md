# r4-f02-lane1 — F02 Edit field permissions R4 复审（收敛第 3 轮）

**结论：1 issue**

- `packages/nocodb/src/models/Permission.ts:354-365` : role-grant 的 granted_role 不变量存在 PATCH 旁路——守卫用 `data.granted_role ?? existing.granted_role` 做校验（显式 `null`/`''` 被 `??` 跳过回落 existing 值），且条件含 `updateObj.granted_type === ROLE`（仅显式切 type 时强制）；`PATCH {granted_role:null}`、`PATCH {granted_role:''}`、`PATCH {granted_type:'role',granted_role:null}` 三载荷均 200 落库 null/空-role 的 role grant，SDK `evaluatePermission` 判 `PermissionRolePower[null]=undefined → false` = deny-all（仅 owner 直通），字段对 editor/creator 全锁死且无告警 : 建议按「最终落库值」判定——`'granted_role' in data ? data.granted_role : existing.granted_role`，targetType===ROLE 且值为 null/''/缺失时 400（R3 commit 声称该不变量 update 面全覆盖，此为同族旁路）

严重度注：仅 creator 可达（meta ACL creator+），错误方向 deny-all（fail-closed，无数据泄露），但直接违反 R3 修复目标不变量 2 的完整性，API 直调可静默锁死字段。按裁决规则属实际违反 → 计数重置、需修复后重审。

---

## 1. R3 修复逐项（commit a8fc2c2966）——全 PASS

| # | 场景 | 预期 | 实测 | 判定 |
|---|---|---|---|---|
| A0 | create nobody grant (Secret 列) | 200 | 200 | PASS |
| A1 | PATCH {nobody+subjects[user]} | 400 且 DB subjects=0 | 400 `subjects are not allowed on nobody grants`；subjects=0 | PASS |
| A2 | PATCH {role} 无 granted_role（nobody→role） | 400 | 400 `granted_role is required for role grants` | PASS |
| A3 | PATCH {role+creator}（nobody→role） | 200，DB granted_role=creator、subjects=0 | 200；DB 一致 | PASS |
| A4 | create user grant 无 subjects | 400 | 400 | PASS |
| A5 | nobody→PATCH {user} 无 subjects | 400 | 400 `subjects are required for user grants` | PASS |
| A6 | PATCH {nobody+subjects:[]}（空数组） | 200 且 subjects 清 0 | 200；subjects 1→0（重建后 nobody 清理生效） | PASS |

## 2. 全矩阵——PASS（nobody/role/user × editor/creator/owner × 5 数据路径）

grant 置于 `Secret` 列（RECORD_FIELD_EDIT），表 `f02r4l1_t`（base `ped67xbyh7k4hid`，表 `mhvdmbnas8xlp4c`）：

- **C0 role/editor 基线**：editor/creator/owner PATCH Secret 全 200；无 grant 的 Title 列 fail-open 可写
- **C1 nobody**：editor/creator PATCH Secret 403、owner 200；editor insert 带该字段 403、不带 200；owner insert 200；bulkInsert 数组同判（带字段 403/不带 200）；v1 PATCH（`/api/v1/db/data/noco/:base/:table/1`）同判；v1 insert（POST 同路由）editor 带字段 403/owner 200/不带 200
- **C2 user subjects=[editor]**：editor PATCH/insert 200；creator 403；owner 200；v1 creator 403；DB subjects=1
- **C3 role/creator**：editor 403、creator 200、owner 200
- **C4 删 grant → fail-open**：editor/creator PATCH、editor insert 全恢复 200
- **C5 即时性**：create nobody 后紧接数据写立即 403；PATCH 切 user+subjects 后紧接 editor 200/creator 403（无陈旧窗口）
- **C6 bulk 更新**：nobody 下 editor `PATCH /records`（数组 body 含 Secret）403、owner 200

审查对象路径执行确认：updateByPk(2815)、insert(insert.ts 复用 fieldPermissionEntityIds)、bulkInsert/bulkUpdate(bulk 路由)、v1 数据路由（共享 BaseModelSqlv2 方法）均经 checkPermission。

⚠️ 过程说明（E3 排除依据）：初跑 C2/C5 报 400，经 bash -x + 响应体捕获定位为**本 lane 测试脚本的 bash 嵌套引号 bug**——`echo "$(fn "{\"json\"}")"` 模式致载荷碎裂，server 返回 `ERR_INVALID_JSON` 400×3（backend.log 同时刻仅 JSON parse 记录，无业务异常）；载荷改经变量/文件传递后 C2/C5 全 PASS，同载荷 30 连发 200。server 行为自始正确，不计 error。

## 3. 旁路 issue 实测证据（B 组）

前提 grant：`role/creator`（A3 产物，Secret 列）：

| # | 载荷 | HTTP | DB 落库 | 数据面效果 |
|---|---|---|---|---|
| B1 | `{granted_role:null}` | 200 | role/NULL | editor 403、creator 403、owner 200（对照：修复前 role/editor 时 editor 200） |
| B4 | `{granted_role:''}` | 200 | role/''（len=0） | editor 403 |
| B5 | `{granted_type:'role',granted_role:null}`（existing=role/editor） | 200 | role/NULL | 同 B1 |
| 对照 | `{granted_type:'role',granted_role:'editor'}` 合法切换 | 200 | role/editor | editor 200 恢复 |

根因（对照源码 Permission.ts:354-365）：守卫判定 `!((data.granted_role ?? (existing).granted_role) as string) && updateObj.granted_type === ROLE`——①`null ?? x` 回落使显式 null 用 existing 值通过校验，落库却写 updateObj 原值 null；②空串/仅 type 不切时条件短路。上游 SDK 侧 `evaluatePermission`（nocodb-sdk/src/lib/permission/index.ts:364-376）对 null granted_role 判 false 属预期 deny 行为，问题在 model 守卫未闭合。

## 4. 代码复审（update() 重构全流）

- 顺序正确：`Permission.get(existing)` → `validateGrantShape`（merged type+role 的 enum/minimumRole、subject 形状）→ granted_type enum → resolved-type 三守卫（任一 400 时**零写入**，DB 状态经 A1 实测不变）→ `metaUpdate`（nobody 时 granted_role 置 null）→ `data.subjects` 存在时先删后建 → nobody 兜底清理 → `Permission.get` 返回。载荷顺序无关性成立（A6 空 subjects 数组 + A1 矛盾载荷双验证）。
- updateObj 空载荷：`PATCH {}` / 仅 subjects 的 PATCH 跳过 metaUpdate，仅 subjects 重建，返回正确（C5 delete 后 fail-open + subjects 计数佐证）。
- 错误消息三条与触发条件一一对应，无误导。
- controller/service 头注释与 acl.ts:279-282/559 一致（permissionList editor+、CUD creator+）。
- 非阻塞观察（不计 issue）：user grant 上 PATCH {granted_role:'editor'}（不带 type）会给 user grant 填无语义的 granted_role（SDK user 分支不读该字段），属脏数据非行为缺陷。

## 5. 回归

- F05：variables create（key 大写校验触发→UPPER_SNAKE 200）/list/delete 200
- F07：snapshot create → status processing→completed，list 200
- F08：private base create 200（is_private 路径）
- F10：dashboard create/list 200
- jest：26 passed / 26 total（packages/nocodb，54s）
- tsc：`npx tsc --noEmit` exit 0，无输出

## 6. 环境与证据

- 后端 http://localhost:8080（未重启）；dev DB `qnap.elf-balance.ts.net:5432/nocodb-dev`（凭证经 Infisical KDL 运行时拉取，未落任何 git 跟踪文件）
- 测试脚本与中间产物：`.work/ee-ce/r4-lane1/`（01-setup / 02-r3 / 03-bypass / 04-matrix / 05-matrix-fixed / 06-seq / 07-c2c5-final + .dbenv/.env.test 本地凭证，勿提交）
- 测试残留：base `ped67xbyh7k4hid`（f02r4l1_base_1789343097）grants 已清零；f02r4snap/dash/private base 留 dev 库（容许）
- 无外部限制（E3 无）；C2/C5 初跑 400 已归因脚本 bug（见 §2 说明），非环境/产品问题
