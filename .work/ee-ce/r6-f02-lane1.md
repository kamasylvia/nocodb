# F02 R6 lane1 复审报告（收敛第 5 轮，2026-09-13）

## 结论

**PASS**（无 F02 error。E3 一项：上游 bulkUpsert update 分支 500 阻断三键修复的运行时直测，已用等价手段闭环，证据见 E3 节。）

审查对象：4b26d7a23f(实现) + e85a421d92(R1) + 3b9dcbdbc6(R2) + a8fc2c2966(R3) + b95fbf7f74(R4) + 10e8d92729(R5)。注意：**工作区另有未提交改动**（见「提交卫生」节），dev server 实测的是当前工作区代码。

## R5 修复逐项验证

| 项 | 断言 | 结果 |
|---|---|---|
| R5-① create | `POST permissions {granted_type:nobody, subjects:[user]}` → 400 `subjects are not allowed on nobody grants` | PASS |
| R5-① update 显式 | PATCH `{granted_type:nobody, subjects:[user]}` → 400 | PASS |
| R5-① update 隐式（双层守卫） | existing nobody + PATCH 仅 `{subjects:[user]}` → 400；grant 原行保持 nobody/subjects=0 | PASS |
| R5-① clean create | `POST {nobody}` 干净 → 200 | PASS |
| R5-① clean update | PATCH `{granted_type:nobody}` → 200，且 granted_role 置空（null）、subjects 空 | PASS |
| R5-① 即时性 | nobody 落库后 editor PATCH 该列立即 403（无缓存延迟） | PASS |
| R5-② 三键匹配 | 运行时直测被上游 500 阻断（E3）；等价验证：源码逐字内联复刻执行 9/9 PASS——column_name/title/id 三键均命中、title≠column_name 的 title 键载荷命中（修复前 find(column_name-only) 漏匹配）、system/pk/FK 排除、空/null/未知键安全 | PASS（等价验证） |

## 全矩阵集成测试（base plwgljy86a31z1o，owner f02r6l1-owner[psql super]、creator、editor、匿名）

**nobody grant（Secret 列）**：
- editor：v2 PATCH 403 / v2 insert 403（带列）/ 200（不带列）/ v1 insert 403 / v1 update 403 / bulkInsert 403 / bulkUpdate 403 / bulkUpdateAll 403 / bulkUpsert（update 分支带列 403；insert 分支带列 403） — 全 PASS
- creator：PATCH nobody 列 403 PASS；owner：v2 PATCH / bulkInsert / bulkUpdateAll / bulkUpsert 全 200（直通）PASS
- fail-open：删 grant 后 editor 立即恢复 200（PATCH）PASS

**role grant（Title 列，granted_role=editor）**：editor PATCH 200 PASS；editor bulkUpsert update 分支带 denied 列（Secret nobody）403 PASS。

**user grant（Title 列，subjects=[editor]）**：editor 200 PASS；creator（不在 subjects）403 PASS；owner 200 PASS。注：subjects id 需真实 user id，错 id 导致 deny 为正确语义（白名单）。

**v1 路由**：insert/update 全 403/200 分界正确 PASS。

**LTAR/link**：
- mm link 写经 bulkUpsert→updateLTARCols（bulkUpsert 3920-3938 以 title 键构建 linkUpdateDatas——源码证据）：update 分支被上游 500 阻断（E3）；insert 分支 link 无 grant 时 fail-open。
- v2 PATCH records 带 mm 数组载荷被上游静默忽略（updateByPk 仅 bt 单字段走 addChild，见 BaseModelSqlv2.ts:2895-2904）——link 未落库（junction 0 行），非权限绕过。
- bt 单字段 PATCH 路径因 bt 列经 v2 columns API 创建失败（API 忽略该载荷）未实测；addChild 等 5 挂点为 CE 预置调用点 + checkPermission 实装即生效，R1-R5 已覆盖。
- V3 bulkUpdate：上游 LTAR 行为不稳定（422/200 交替、link 不落库 junction 0），未取得有效运行时证据（E3 关联）。

**公共表单（form view c21ad8e2，v2 public rows）**：
- 匿名提交含 nobody 列（Secret，enforce_for_form 默认 true）→ 403 PASS
- 匿名 clean 提交（无 grant 列）→ 200 PASS
- PATCH enforce_for_form=false → 同载荷立即 200 PASS；恢复 true → 立即 403 PASS（即时性）
- user-grant 列（Title）对匿名提交者：载荷含该列 → 403（白名单语义正确）PASS

**代码复审**
1. `Permission.ts validateGrantShape`（R5 拒绝）与 update 早期守卫（Permission.ts:363-367）双层一致性：语义相同（`data.subjects?.length` 同判），覆盖显式/隐式/clean+空数组全组合（subjects:[] 与 nobody 组合走后置清理 metaDelete，落到 nobody/subjects=0 不变量）。无冲突无漏洞。
2. 三键误匹配（title 与 column_name 交叉重名）：**工作区未提交改动已修复**——fieldPermissionEntityIds 由 find()-first-match 改为收集所有命中列入 Set（over-block 安全方向），交叉重名时两列同入检查集。内联复刻执行确认（`cross-duplicate collects both` PASS）。理论风险关闭。
3. datas.service.ts:1213 传 `param.cookie`（R1 修复）后 view submit 认证路径 user 可解析；public-datas 仅匿名路径标 isPublicForm——分工正确。
4. skipValidationAndHooks:true 三处均在 columns.service.ts（select option 删除迁移的服务端可信路径）——豁免合理。
5. Permission.list 免缓存决策（R1 注释）+ context.permissions 请求级复用；bulkUpsert 多行合并 entityIds 单次调用——无 N+1 放大。

## 回归

- jest：**26/26 PASS**（baseVariableValidators.Fork / uniqueConstraintHelpers.Fork）
- tsc --noEmit：**0 错误**（含工作区未提交改动）
- F05 variables：create(key/value/type) 200、list 200 ✓
- F07 snapshots：list 200、create（duplicateBase 链路）200 ✓（顺带证明复制路径不被 F02 挂点误拦）
- F08 private base：创建 is_private 200、owner 可见 200、editor GET 404（masked）✓
- F10 dashboards：create/list 200 ✓

## E3（外部限制，非 error）

**上游 bulkUpsert update 分支 500**：`POST /api/v1/db/data/bulk/noco/:b/:t/upsert` 带 PK 的 update 分支稳定 500（`TypeError: Cannot read properties of undefined (reading 'Id')` @ BaseModelSqlv2.ts afterUpdate ~6013，updatedDataList undefined）。非 fork 引入：① F02 六 commit diff hunk 不含 3938-4171 区域；② owner 直通（checkPermission 第一行 return，未执行任何 F02 逻辑）同 payload 同 500；③ F02 的 403 在 split 前正确抛出。后果：经 bulkUpsert 触发 updateLTARCols 的运行时直测被阻断，三键修复以「源码逐字内联复刻执行 9/9」等价闭环。待办：上游修复后重跑 bulkUpsert update-branch e2e（V3 bulkUpdate 的 LTAR 不稳定行为可一并复验）。

## 提交卫生（提醒 orchestrator）

- 工作区有**未提交**改动：`packages/nocodb/src/db/BaseModelSqlv2.ts`（fieldPermissionEntityIds Set 全收集 + R6 注释，封交叉重名风险）；`-X`、`PATCH` 两个杂项文件已删（R5 commit 10e8d92729 误入，工作区删除待提交）。本轮全部实测基于该工作区代码（rspack 已加载），报告结论对其有效；请尽快 commit 固化。
- 测试残留：nc_permissions/subjects 中 f02r6l1-* 数据及 base plwgljy86a31z1o（含快照/变量/dashboard 各 1），nocodb-dev 库，未清理（可留作下轮对照或统一清）。

## 证据索引

- 测试脚本/中间产物：`.work/ee-ce/tmp-r6l1/`（env.sh[含 token，勿提交] / setup / three-key-inline.ts）
- 三键等价验证输出：9 PASS（three-key-inline.ts，逐字复刻工作区版 fieldPermissionEntityIds + sdk isSystemColumn）
- 关键响应样本已内嵌上文各表
