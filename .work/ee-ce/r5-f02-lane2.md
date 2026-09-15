# F02 R5 lane2 复审报告（集成测试 + 代码复审，收敛第 4 轮）

对象 commit：4b26d7a23f（实现）/ e85a421d92（R1）/ 3b9dcbdbc6（R2）/ a8fc2c2966（R3）/ b95fbf7f74（R4 修复，本轮重点）
环境：dev backend :8080 + nocodb-dev（qnap.elf-balance.ts.net:5432）；测试账号前缀 `f02r5l2-*`（owner/creator/editor/editor2/viewer）；base `p6ponlp1nyh4bu8`，table `mzfrm9dwuxzs45x`，列 Title `cnni9cw5vi6dfxk` / Amount `c7dcf31ouaw14f8` / Note `ct9qkvj8qhgliaw`。

## 结论

1 issue（minor，语义不对称，无安全影响）：

- `packages/nocodb/src/models/Permission.ts:158`（insert 校验块 202-219）:create 路径接受 `granted_type=nobody` + subjects（实测 200，subject 行落库，见 T3 证据），而 R3 在 update 路径（同文件 :353）以「contradictory payload」为由 400——同一不变量两条路径不对称，create 落库死数据（evaluator 对 nobody 忽略 subjects，deny-all 不受影响，subjects 无法放大权限，无安全通道；UI 也不产此 payload）:建议在 `insert()`（或 `validateGrantShape`，create/update 共用）补同款 nobody+subjects 拒绝。

其余全部通过（T1 R4 修复验证 / T2 生命周期 / T3 校验矩阵 / T4 enforcement / T5 代码复审矩阵均 0 error）。观察项 3 条（非 error，见 §6）。

## T1 R4 修复验证（本轮核心）— 全过

前置：Note 列 role grant（granted_role=editor）；Amount 列 user grant（subjects=[editor]）。

| # | 操作 | 期望 | 实测 | DB 断言 |
|---|---|---|---|---|
| 1.2 | PATCH `{granted_role:null}` 于 role grant | 400 | 400 `granted_role is required for role grants` | role\|editor 不变，无 null-role 落库 |
| 1.3 | PATCH `{granted_role:""}` | 400 | 400 同上 | role\|editor 不变 |
| 1.4 | PATCH `{granted_type:"role",granted_role:null}` | 400 | 400 同上 | role\|editor 不变 |
| 1.5 | PATCH `{granted_role:"creator"}` | 200 | 200 | role\|creator 落库正确 |
| 1.6 | PATCH `{granted_role:"bogus"}` | 400 | 400 `Invalid granted_role bogus` | role\|creator 不变 |
| 1.7 | user 行 PATCH team subjects（不带 granted_type） | 400 | 400 `Team subjects are not supported yet` | user\|editor subjects 不变 |
| 1.9 | 同上且带 `granted_type:"user"`（对称） | 400 | 400 同上 | 不变 |
| 1.10 | create 直接带 team subject | 400 | 400 同上 | 未创建 |

R4 两条修复（键存在语义 + resolved target type）均实测生效，前身报告的 null/空绕过与 team subjects 旁路已闭合。

## T2 生命周期回归（Title 列单 grant 往返）— 全过

| 步骤 | 操作 | http | DB（type\|role\|subjects） |
|---|---|---|---|
| 2.1 | create nobody | 200 | nobody\|NULL\|nosubj |
| 2.2 | →user + subjects=[editor] | 200 | user\|NULL\|user:editor |
| 2.3 | →nobody（subjects 省略） | 200 | nobody\|NULL\|nosubj（subject 行清除） |
| 2.4 | →role + creator | 200 | role\|creator\|nosubj |
| 2.5 | →user + subjects=[editor2] | 200 | user\|creator\|user:editor2（stale role 观察项 O1） |
| 2.6 | delete | 200 | 行删除，回 fail-open |

## T3 校验矩阵（create/update 对称性）

create（Title 列逐个建删）：role+editor 200；role+null / role+'' / role 缺省 400；role+viewer（低于 minimumRole editor）400；user 无 subjects 400；subject 缺 id 400；granted_type=bogus 400；nobody 裸 200；nobody+subjects **200（即上述 issue）**；重复 (entity,entity_id,permission) 400；非法 entity 400；不存在 column 400（`Column c_nonexistent not found`）。

update（Amount user grant）：granted_type=bogus 400；`{granted_type:"role"}` 无 role 且 existing NULL 400；空 body 200 no-op；`subjects:[]` 400 且 DB 不变；nobody+subjects 400（update 侧守卫生效）；换 subjects 200；`granted_role` editor/null/'' 于 user grant 均 200（观察项 O2）。

## T4 enforcement 矩阵（v2 数据 API 实测）

grant 配置：Note=role:creator；Amount=user:[editor]。

| 场景 | editor | creator | editor2 | viewer | owner |
|---|---|---|---|---|---|
| PATCH Note（role:creator） | **403** 字段名报错 | 200 | — | （ACL 403 先行，语义上不可达） | 200 |
| PATCH Amount（user:[editor]） | 200 | **403** | **403** | 同上 | 200 |
| PATCH Title（无 grant） | 200（fail-open） | — | — | — | — |

nobody 切换后：editor/creator PATCH Note 均 403，owner 200（owner 直通）。
insert 路径：nobody 下 owner 带键 insert 200；editor 带 Note 键 403；editor 不带 Note 键 200（只查写入键，正确）。
bulk PATCH 路径：数组含 Note 键 403；仅 Title/Amount 200。
ACL 边界：editor GET permissions 200 / POST·PATCH·DELETE 403；viewer GET 403；无认证 401。全部 0/400/401/403，无 500。

## T5 代码复审：granted_role 落库值矩阵

静态链路（`Permission.update` × SDK `extractProps` 只排 undefined，`commonUtils.ts:10`）+ 实测：

| payload granted_role | validation 输入 | updateObj 含键 | grantedRoleToStore | ROLE 目标结果 | DB |
|---|---|---|---|---|---|
| null（role 目标） | undefined | 是(null) | `''` | 400（T1.2） | 不变 |
| ''（role 目标） | '' | 是('') | `''` | 400（T1.3） | 不变 |
| 合法（role 目标） | 合法 | 是 | 合法 | 过（enum+minimumRole） | 落库（T1.5） |
| 缺省（role 目标） | existing | 否 | existing | existing 空→400（T3），非空→回落 | existing 保持 |
| null（user 目标） | — | 是(null) | null | n/a | NULL 落库（T3 实测） |
| ''（user 目标） | — | 是 | '' | n/a | '' 落库（O2） |
| 缺省（user 目标） | existing | 否 | existing | n/a | 保持 |

关键边界实测：existing grant（user|NULL）PATCH `{granted_type:"role"}`（不命名 role）→ 400；nobody 切换强制 `granted_role=NULL` 落库（T2.3）；stale-role 复活探针——nobody grant 上先种 `granted_role:viewer` 再 PATCH `{granted_type:"role"}` → 400（minimumRole 拦截无效值复活），种 editor → 复活 role|editor（合法值回落，等价显式 PATCH，见 O1/O3 判定）。R4 的「null/'' 不回落」与「ROLE 空值 400」在所有格均闭合，未发现可落 null-role 行的通道。

## 观察项（非 error）

- O1 role→user 转换遗留 stale granted_role（T2.5 `user|creator`）；SDK evaluator 对 USER 类型忽略 granted_role，UI `getPermissionOptionValue(USER)` 同样忽略，无语义影响。
- O2 user grant 可写 `granted_role:''`（T3）；纯脏值，evaluator/UI 均不读；切回 role 时 `''` 触发 400 不会复活。
- O3 stale 合法 role 可在 `{granted_type:"role"}` 不命名 role 时复活（T5 探针）；属「回落到既有列值」的设计内语义（显式 null/'' 已被 R4 拒绝），复活值必经 enum+minimumRole 校验，无 deny-all 通道；UI 恒发完整 option 不触发。

## R4 前端 diff 复核（静态）

- `Form.vue:1832,1893`：`element?.permissions?.isAllowedToEdit !== false` 渲染前隐藏受限字段；producer 在 `useViewData.ts:414`（getter，响应式）与 `useSharedFormViewStore.ts:343`，未加载时 undefined→显示（宽到窄，安全方向）。无错误。
- `dlg/Field/Permissions.vue`：onBeforeUnmount 复位 visible、`option-filter-prop="label"` 按邮箱/显示名过滤——静态无问题（UI 行为本 lane 无浏览器验证，R4 commit 自测 e2e 22/22）。

## 收尾状态

测试数据遗留于 nocodb-dev（base `p6ponlp1nyh4bu8` 前缀 `f02r5l2-*`，Note=role:creator、Amount=user:[editor] 保持原状）；无凭证入 git/.work 明文；未重启/未杀任何进程；全程无 E3 外部限制。
