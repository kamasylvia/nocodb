# F02 Edit field permissions — R5 lane1 复审报告（收敛第 4 轮）

## 结论

issues（1 项 minor，非 R4 引入，无安全危害）：

- `packages/nocodb/src/models/Permission.ts:158-239 (insert)：POST nobody+subjects 返回 200 并将 subjects 写入 nc_permission_subjects，与 update 侧 400（Permission.ts:353-357「subjects are not allowed on nobody grants」）不对齐：建议在 insert 内对 granted_type===NOBODY 且 subjects 非空返回 400（实测 SDK evaluatePermission 对 NOBODY 无条件 return false，残留 subjects 行为惰性数据，无提权风险）`

其余全部通过：R4 五项修复逐项验证 ✓、全矩阵 34/34 ✓、ACL 8 项 ✓、回归 F05/F07/F08/F10 ✓、jest 26/26 ✓、tsc 0 ✓。

---

## 1. R4 修复逐项验证（commit b95fbf7f74）

### ① granted_role 键存在语义（role grant）— 6/6 通过
对 `granted_type=role, granted_role=creator` 的 grant 依次 PATCH：

| 断言 | 结果 |
|---|---|
| PATCH `granted_role:null` | 400 "granted_role is required for role grants" ✓ |
| PATCH `granted_role:''` | 400 ✓ |
| PATCH 不带 granted_role（仅 enforce_for_form） | 200，DB 中 granted_role 保持 `creator` ✓ |
| PATCH `granted_role:"editor"`（合法） | 200 ✓ |
| PATCH `granted_role:null` 与其他字段混合 | 400 ✓ |
| PATCH `granted_type:"nobody"` 切换 | 200，stored_role=null、subjects=0 ✓ |

代码组合核查：extractProps（nocodb-sdk commonUtils.ts:16）保留 null 键仅滤 undefined → `'granted_role' in updateObj` 为 true → `grantedRoleToStore = null ?? '' = ''` → 400 触发；data 侧 `'granted_role' in data` 同理把显式 null 送入 validateGrantShape（undefined），不再回落 existing。键存在语义与 extractProps 组合**自洽**。

### ② team subjects update 按 resolved target type 拒绝 — 通过
user grant（subjects=editor）PATCH 场景：

| 断言 | 结果 |
|---|---|
| PATCH `subjects:[{type:'team'}]` 不带 granted_type | 400 "Team subjects are not supported yet" ✓（R4 修复核心，resolvedType=existing.granted_type=USER） |
| PATCH team subjects + 显式 granted_type:user | 400 ✓ |
| PATCH 混合 user+team subjects | 400 ✓ |
| PATCH 合法双 user subjects | 200，subjects 双 uid 落库 ✓ |

### ③ Form.vue 两处渲染位 isAllowedToEdit!==false 隐藏 — 代码核通过
- 两处 `v-if`（Form.vue:1832 可见拖拽区 / 1893 隐藏字段区）的 element 均来自 `localColumns`（useFormViewStore.ts:37）← `setFormData`（Form.vue:978）← `formColumnData`（useViewData.ts:393）。
- `permissions.isAllowedToEdit` 是 useViewData.ts:414 注入的 **getter**（每次访问求值 isAllowed，isFormView:true）；`setFormData` 的 `{...c}` spread 只复制顶层属性，permissions 对象引用不变 → getter 存活且响应式（render effect 收集 permissions/user 响应式依赖），grant 异步加载后自动隐藏。✓
- `!== false` 语义：isAllowed 恒返回 boolean；formColumnData 未加载的过渡态 undefined → 显示（fail-open），加载后隐藏。可接受。
- 配套：submitForm（Form.vue:378）提交时剥离受限字段数据；后端 insert/update hook 为最终防线（矩阵验证）。

### ④ 弹窗 onBeforeUnmount 复位 visible — 代码核通过
- Permissions.vue:203-207 `onBeforeUnmount` 内 `if (props.visible) emit('update:visible', false)`。
- emit 接收方确认：ColumnMenu.vue:995 `v-model:visible="showFieldPermissionsModal"`，emit 同步置父 ref false。模式正确；具体 teleport 时序依赖 ant-modal 内部 watch，R4 自测 e2e 22/22 覆盖，本轮无回归证据（API 层无法复验 DOM，不判 error）。

### ⑤ Specific users 多选 option-filter-prop=label — 通过
Permissions.vue:253 `option-filter-prop="label"`，options 映射 `{value: m.id, label: m.label}`，label = `display_name || email`（:57）。按 email/显示名过滤 ✓。

## 2. 全矩阵集成测试（34/34 PASS）

环境：dev server :8080（nocodb-dev），owner（psql 提权 super）/editor/creator 三账号，base+2 列表（Name/Secret），grant 配在 Secret 列。

- **G1 nobody（12 断言）**：editor/creator 的 PATCH/insert/bulk/v1 全 403；owner 全 200 ✓；grant 建立后首个请求立即 403（即时性，无缓存延迟）✓
- **G2 role:editor（5）**：editor/creator PATCH/insert/v1 全 200 ✓
- **G3 role:creator（7）**：editor 403（PATCH/bulk/v1），creator 200，owner 200 ✓
- **G4 user:[editor]（6）**：editor 200，creator 403（user grant 与角色无关，subject 名单决定）✓
- **G5 user:[creator]（2）**：creator 200，editor 403 ✓
- **G6 fail-open 恢复（1）**：删 grant 后 editor PATCH 恢复 200 ✓
- **G7 enforce_for_form=false 不抬数据面 deny（1）**：nobody+opt-out 下 editor PATCH 仍 403 ✓

owner 直通每组抽验均通过；v1 路由（`/api/v1/db/data/noco/...` 与 bulk `/api/v1/db/data/bulk/...`）均在 hook 覆盖内。

## 3. 权限管理面 ACL（8/8）

- editor LIST grants → 200（permissionList editor+）✓
- editor CREATE/DELETE/PATCH grant → 403 ✓（permissionCreate/Update/Delete creator+）
- creator CREATE/DELETE grant → 200 ✓

## 4. 回归抽测

- F05 variables：list/create(key,value)/update/delete → 200 ✓（初次 400 为测试 payload 用错字段 name≠key，service 校验行为正确）
- F07 snapshots list → 200 ✓
- F08 base meta 含 is_private 字段 ✓
- F10 dashboards list → 200 ✓
- jest：2 suites / **26/26 passed**（uniqueConstraintHelpers.Fork + baseVariableValidators.Fork）
- tsc `--noEmit`：**0 error**

## 5. 测试数据清理

测试 base 删除（200）、f02r5l1-* 用户行删除（DELETE 3）、grants 0 残留。

## 6. E3 外部限制/环境记录（非 F02 error）

1. **Infisical KDL `DB_NAME` secret 值为 `nocodb`（生产库名）**：按任务书给的凭证拉取流程直连会命中生产库。本轮首次 psql 探活误连 `nocodb` 库，全部操作仅为 SELECT 与一条 `UPDATE ... WHERE email='f02r5l1-...'`（零行匹配，UPDATE 0），**零数据污染**（已验证生产库 0 行 f02r5l1 残留）。已改 `.work/ee-ce/r5l1-common.sh` 显式硬编码 `nocodb-dev` 并注释警示。建议：修正 Infisical KDL 项目 `DB_NAME` secret 值，或在 dev-backend.sh 同款脚本层强制覆写。
2. 本 shell 沙盒下 zsh 多行脚本中「管道+命令替换」偶发 `failed to change group ID`（setpgid 被拒），改 bash + 文件中转规避；与被测系统无关。
