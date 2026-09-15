# R7 F02 复审报告 — lane1(同规格编制首轮)

**结论:PASS**(0 error。6 commit + R6 修复全部验证通过;主套件 71/74 + 补充 10/10 + v3 追加 3/3 = 实际 84/84 行为断言全对,3 个套件失败均归因为测试脚本自身 bug,非产品问题,详见 §3.0)

审查对象:git diff 4b26d7a23f^..HEAD(24 文件,+1626/-56)。隔离:仅读 TASK.md / 仓根 AGENTS.md / f02-research.md / 源码 / git diff。

---

## 1. R6 修复验证(重点)— PASS

碰撞布局精确复刻 commit message 场景:collide 表先建 colY(title TmpY → 后改名 title=Q2,column_name 保留 TmpY),再建 colX(title Q2 → 后改名 title=QX,column_name 保留 Q2)。getColumns 顺序 colY 在前。colX 挂 nobody grant。

| 断言 | 结果 |
|---|---|
| editor v2 PATCH `{Id,Q2}`(碰撞键) | **403**(R6 前 find() 命中 decoy colY → 200)✅ |
| editor v2 PATCH `{Id,QX}`(colX title 键) | 403 ✅ |
| editor v2 PATCH `{Id,TmpY}`(decoy 真列) | 200 ✅(decoy 本身不受限,过度拦截边界正确) |
| editor v2 PATCH `{Id,Q2,Title}` 碰撞键混自由字段 | 403 ✅ |
| owner 同载荷 `{Id,Q2}` | 200 ✅ |
| editor v1 insert POST /api/v1/db/data/noco/:base/:tab `{Q2}` | 403 ✅ |
| editor v3 POST /records `{"fields":{"Q2":...}}` | 403,错误消息正确指向 QX ✅ |
| editor v3 PATCH `[{"id":..,"fields":{"Q2":..}}]` | 403(先于 404 判定,fail-closed 顺序正确)✅ |
| owner v3 PATCH 同载荷(真实行) | 200 ✅ |

无碰撞对照表(control:Secret/Plain 无交叉重名)正常 403/200 分界,无过度拦截。

实现核(`BaseModelSqlv2.ts:10529-10558`):双重循环收集**全部**命中列入 `Set`(去重),单过滤谓词(system/pk/ForeignKey/isSystemColumn)对每个命中独立评估;歧义键 over-block = 安全方向。空 payload → `[]` → checkPermission 循环跳过 = fail-open,正确。

**附带核验**:v2 PATCH 碰撞键写值后逐列读回(colX 物理 Q2 有值,colY 物理 TmpY 为 null)→ 物理单列写入,无双写;readback JSON 中 Q2/QX 同值为**读回键碰撞显示假象**(title 与 column_name 交叉列在上游 CE 读回形状下的固有表现),非 F02 diff 引入,不判违反。

## 2. 代码复审(整个 diff)— PASS

### 后端
- **数据路径挂点全覆盖**:updateByPk(:2815)、nestedInsert(:3057,v1 insert + 公共表单汇聚点,带 isFormContext)、bulkUpsert(:3656,raw 跳过=可信内部路径)、bulkUpdate(:4496,raw 跳过)、bulkUpdateAll(:4790,skipValidationAndHooks 跳过)、updateLTARCols(:4724,补 R2 前缺口)、insert.ts single(:69)与 bulk(:345,受 skipPermissionCheck 门控)。import.service 三处 `skipPermissionCheck:true` + raw:true 均落在跳过通道,复制/导入/快照路径免检(S2 实测快照 completed 佐证)。
- **checkPermission**(:10568-10678):owner 直通;`req.context ?? this.context` 解 R1 缓存实例错位;`req.permissions` 优先(兼容 MCP 预载)否则 Permission.list;无 grant → fail-open(上游契约);匿名 + 非 form 上下文一律拒;多 grant 全评估任一拒即 403(顺序无关,S1 双 grant 实测);错误消息只含列 title,不泄漏内部 id/结构。
- **Permission model**:list 刻意无缓存(R1 决策,注释载明 NocoCache 键空间坑,查微小索引表);update() resolved-type 三守卫顺序正确(validateGrantShape resolved type → nobody+subjects 拒 → granted_role 终值语义拒 → user subjects resolved 拒),写前校验、写后 subjects 重建、nobody 强制清 subjects + granted_role 置 null(S1.4g 实测 `null//0`);validateGrantShape 共享 enum/minimumRole/subjects 形状校验,create 带 requireSubjectsForUser、update 由 resolved-type 补齐,对称。
- **permissions.controller/service**:v1+v2 双路径 + @Acl 四 op;service 层 synced 表拒配、table-entity 拒(F02 范围)、FIELD×非 RECORD_FIELD_EDIT 拒、单 (entity,entity_id,permission) 唯一性、team subject 拒、跨 base grant 拒。
- **acl.ts**:permissionList 挂 EDITOR(只读,驱动前端 lock 图标),Create/Update/Delete 落 creator 基线(T4.19-4.23 实测分界)。
- **Base.ts**:softDelete/hardDelete 两路径补 `Permission.deleteByBaseId`,无孤儿行。
- **datas.service**:dataInsert 把 `null` request 改传 `param.cookie`(R1,修复 v1 插入路径 user 解析 fail-open),且正确地不标 isPublicForm(该路由也服务鉴权视图提交)。
- **public-datas.service**:匿名提交路径置 `req.isPublicForm`,与 nestedInsert 挂点的 isFormContext 判定联动。
- **探针残留**:diff 全文 grep console./debugger/TODO/FIXME = 0。R6 顺带清除 R5 误入的两个垃圾文件(PATCH、-X)。

### 前端
- **useEeConfig**:仅 `blockTableAndFieldPermissions`→false,未动 isEeUI(符合仓规"勿全局翻转")。
- **gate 改法**:View.vue(升级弹窗仅 block 时触发、tab 路由去 isEeUI、tab 可见性 flag+sourceCreate)、Details.vue(permissionsTab 去 showEEFeatures/isEeUI)、ColumnMenu(菜单项 `!blockTableAndFieldPermissions`,弹窗挂载去 isEeUI)——与 F05/F07 解 gate 先例一致。
- **usePermissions**:惰性每 base 装载 + base 切换失效重拉 + force 绕过守卫(R2);isAllowed owner 直通与后端对齐;**grants[0] 语义**:受 create API 单 grant 唯一性约束下与后端全评估等价(psql 直插多 grant 时前端显示可能偏宽,但后端权威拒绝,Advisory 层差异,不判 error)。
- **useViewData**:isAllowedToEdit 改惰性 getter(R1,修静态快照冻结 grant 装载前状态)。
- **Form.vue**:无权字段 `isAllowedToEdit===false` 在两处渲染分支隐藏。
- **Permissions.vue 弹窗**:默认态=无 grant 行(EDITORS_AND_UP 选项触发 delete 而非写 EDITOR grant,与 fail-open 语义吻合);user grant 需选人;卸载时复位 visible;onBeforeUnmount 防 ant-modal teleport 残留。
- **Modal/Content.vue**:permissions tab 主体实装,F03 范畴留只读默认提示。
- **i18n**:permissionUpdated(en+zh-Hans)补齐;引用的既有键(selectUsers/editFieldPermissions/resetFieldPermissions)均在。

## 3. 集成测试(nocodb-dev 实测,dev server :8080 含 R6 修复)

### 3.0 测试基建说明(3 个套件失败的归因,非产品问题)
macOS bash 3.2 在「双引号包裹的 `$( )` 内」对含逗号的 `{a,b}` 花括号做 brace expansion,吞掉 curl JSON body 的花括号 → 服务端 ERR_INVALID_JSON 400。凡此 400(27 处)均属此机制,与权限逻辑无关。改用 printf 构造 body 重测后全部通过;T5/T6 另修正两处测试自身错误(公共表单 body 需包 `data` 键;F05 variable key 需 UPPER_SNAKE_CASE + type∈{text,secret}——均为 F05 既有约束)。修正后全部断言通过。

### 3.1 主套件(71 PASS / 3 脚本 bug 归因)
- **T1 R6 碰撞劫持**:6/6(§1 表)。
- **T2 全矩阵**(control 表,Secret 受限/Plain 自由):nobody×{editor,creator,owner}×{v2 PATCH, v2 insert, bulkInsert, bulkUpdate, bulkUpdateAll, bulkUpsert(update 分支), v1 insert, v1 update} 拦截/放行全对;自由列 Plain 不受牵连;role:editor(3 角色 200)、role:creator(editor 403/creator 200)、user:ed1(ed1 200/ed2 403/creator 403/owner 200)分界全对;user→nobody 切换后原 subject 立即 403,行上 granted_role 置 null、subjects 清空。
- **T3 fail-open**:无 grant 全角色 200;grant delete 后下一请求 200。
- **T4 校验对称**:create×{nobody+subjects, role 缺 role, user 缺 subjects, role 非法枚举, viewer 低于 minimumRole, 非法 granted_type, 非法 entity, field×TABLE_RECORD_ADD, table entity(F03 范围拒), 不存在 entity_id} 全 400;update×{非法 role, null role, nobody+subjects, →user 缺/空 subjects} 全 400,合法切换全 200;ACL{editor create/patch/delete → 403,list → 200;owner 全通}。
- **T5 公共表单**(data 包裹修正后):匿名受限字段 enforce_for_form=true → 403;false → 200 且 Secret 值实际落库(S2.5 验证);无受限字段提交 → 200;鉴权 editor 非表单上下文不受 enforce_for_form=false 豁免 → 403。
- **T6 回归**:F05 variables list/create 200;F07 snapshots list 200 + 快照创建 completed(受限字段 base 上 duplicateBase 未被自身权限拦截);F10 dashboards list 200;F08 base read 200。
- **T7**:duplicate grant 400、team subject 400、未知 id PATCH/DELETE 404、delete 后 fail-open 恢复。

### 3.2 补充套件(10/10)
- **S1 真·多 grant**(psql 直插 role:creator + user:ed2 同列):ed2(user grant 允许但 role grant 拒绝)→ 403 **any-denial-blocks 实证**;ed1 → 403;creator → 403(user grant 对非 subject 即拒,同语义)。R1「多 grant 顺序无关」达成(注:API 层单 grant 唯一性使该场景仅 psql 可达,系设计使然)。
- **S2 = §3.1 T5 修正后 5/5**。
- **S3 F05**:create(合规 body)200、list 200。

### 3.3 v3 路由追加(3/3)
v3 PATCH/POST 碰撞键 editor 403 / owner 200 / 先权限后 404 顺序正确。

### 3.4 静态
- `cd packages/nocodb && npx tsc --noEmit`:**exit 0**(0 错误)。
- `pnpm test`(jest):**2 suites / 26 tests 全过**(uniqueConstraintHelpers.Fork.spec + baseVariableValidators.Fork.spec)。

## 4. 观察(非 error,不计违反)
1. 前端 usePermissions `grants[0]`/后端全评估:API 单 grant 唯一性约束下等价;psql 直插多 grant 时前端显示可能偏宽(后端仍权威拒绝)。F03 复用时若开放多 grant UI 需回看。
2. 交叉重名列在 v2/v3 **读回** JSON 存在 title↔column_name 键碰撞(两键同显一列物理值),系上游 CE 序列化形状,F02 diff 未触碰读回路径。
3. 本 lane 规格未含浏览器 UI 段;前端按 diff 复审 + gate 逻辑核对(F05/F07 先例一致性)。

## 5. 证据
- 测试脚本与状态:`.work/ee-ce/r7-lane1/{setup.sh,run_tests.sh,supplement.sh,state/}`(state/env.sh 含测试账号邮箱/密码,dev 一次性账号,非真实凭证)
- 测试库 nocodb-dev,base `p0kmqs8euo8cb2w`(collide/control 表 + form 共享视图);测试后 grants 清零
- tsc 日志:`.work/ee-ce/r7-lane1/tsc.log`(空 = 0 错)
