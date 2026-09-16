# R4 F03 Data permissions — lane4 独立复审报告

**PASS（0 error）**

- 审查对象：main ee85ce82c8（F03 实现 7b10716231 + R1/R2/R3 修复链 b28787a54a；其后仅 .work chore 提交，`git diff ee85ce82c8..HEAD -- packages/ src/` 为空，源码与审查目标一致）
- 本实例为重试实例：接管 00:47 阵亡实例的脚本（/tmp/f03r4l4/）完成集成测试；其遗留脚本存在 7 处测试脚本缺陷（见附录 B），已逐一修复并重跑，修复后全部通过——先前 FAIL 均为脚本问题，非产品缺陷。

## 1. 集成测试（API 实测 :8080）

| 套件 | 覆盖 | 结果 |
|---|---|---|
| t1_matrix | fail-open 基线 12 项 + ADD/DELETE × nobody/role(creator,editor)/user × v2 单条/bulk、v1 单插/单删/bulk/deleteAll、upsert 拆分、正交性、duplicate-key、fail-open 恢复 | **46/46 OK** |
| t2_visibility | VISIBILITY nobody：meta/data(v1+v2)/count/groupby/aggregate 全 404、表列表隐藏、跨表隔离；role:viewer / role:creator 档；user 精确匹配；Everyone=删 grant 往返 | **23/23 OK** |
| t3_validation | create 14 项 + update 6 项校验对称（nobody+subjects、role 缺 granted_role、user 缺 subjects、非法枚举、低于 minimumRole、field/table 键错配、不存在表、跨 base 表、重复键）；R3-a/b/c hygiene；ACL 面（editor 403 增删、creator 可建、匿名 401） | **34/34 OK** |
| t4_form_dup_perf | 公开表单 enforce_for_form true→403/false→200/无 grant→200；R3-d duplicate 带 grants；R3-e bulk 100 性能 | **12/12 OK** |
| t5_regression | F02 字段权限 3 项；F05 变量；F07 快照；F08 私有 base 4 项；F10 dashboard | **10/10 OK**（见 §2 F07 补验） |

关键断言（method/path → 状态码）：
- fail-open：无 grant 时 editor `POST /api/v2/tables/:tid/records` → 200；删 grant 后下一请求 → 200（t1 J）
- any-deny：`role:creator` ADD grant 下 editor v2/v1 insert 均 403、creator 200（t1 B）
- upsert 拆分：v1 `POST /api/v1/db/data/bulk/noco/:base/:tbl/upsert` 纯 update 批（无插入行）过 ADD 门后死于上游 afterUpdate 500（500 即门已放行的证据，403 才是回归）；含插入行批 403（t1 N）
- duplicate-key：同 (entity,entity_id,permission) 第二次 POST → 400；换 permission → 200（t1 O / t3 K10）
- VISIBILITY 404 遮蔽：editor 对 Tasks 的 meta/list/insert/count/groupby/aggregate、v1 list/groupby/aggregate 全 404；`?includeAllTables=true` 列表不含 Tasks（t2 G）
- ACL：editor POST/DELETE /permissions → 403；creator POST → 200；匿名 GET → 401（t3 M）

## 2. R3 修复回归验证（b28787a54a，逐项实测）

- **R3-a NOBODY 转换**：PATCH role→nobody 后 GET `granted_role` 为 `null`（type:null）✓；随后 PATCH `{granted_type:role}` 不带 granted_role → **400**（复活守卫）✓；合法 revive → 200 ✓
- **R3-b user→role 切换**：subjects 1 → 切 role:editor 后 → 0 ✓
- **R3-c owner-role grant**：create role:owner → GET 保持 owner；无关 PATCH（enforce_for_form）后仍 owner，不降权 creator ✓
- **R3-d duplicate 带 grants**：源 base 挂 VISIBILITY nobody（表级）+ RECORD_FIELD_EDIT nobody（Secret 列，F02）+ TABLE_RECORD_ADD user:[creator] → `POST /api/v2/meta/duplicate/:baseId` → 副本 /permissions 三条 grant 全部带出，entity_id 分别映射到新表 id（mtng…/ma84… 两次运行均验证）与新列 id，subjects 保留 ✓；行为验证：邀请 editor 进副本后 meta 404（VISIBILITY 生效于副本）、同 base 其他表 200（隔离）✓
  - 注：duplicate **不复制成员角色**（全员 null，仅保留 duplicator 的 owner）——上游 `importUsers` 为 `NcError.notImplemented('Import users not implemented')`（import.service.ts:110），上游 E3 语义，非 fork 缺陷
- **R3-e bulk 性能**：100 行 bulk，无 grant 514ms / role:creator grant 下 creator 47ms —— 同量级（grant 路径反而更快，缓存热），R3 前 ~2x 放大已消除 ✓；grant 对 editor 生效（403）✓
- **代码在位性（diff 全量复核）**：
  - 弹窗 dirty-flag：a-select `@change="states[permission].dirty = true"` + 选项点击均置 dirty（Permissions.vue）
  - SPECIFIC_USERS 单选项无 v-if 死代码（options 由 addDeleteOptions/visibilityOptions computed 过滤，全部渲染）
  - save 前置校验：dirty SPECIFIC_USERS 空选 → `message.error` + return，发生在任何写操作之前（不删既有 grant、不假成功）
  - owner-role 回显：`originalRole` 保存 CREATORS_AND_UP→owner 不降级
  - importPermissions（import.service.ts:173）：`getIdOrExternalId` 重映射 entity_id、subjects 仅留 `type:user`、逐 grant try/catch（logger.debug 跳过，不中止导入）✓

## 3. UI 段（camoufox，:3000）

- 前实例证据截图核验通过：
  - `/tmp/f03r4l4/ui1-permissions-tab.png`：Details → Permissions tab，三 key 摘要（Who can add records / Who can delete records / Table Visibility = Everyone）与 API `[]`（无 grant = Everyone 缺省）一致；Field permissions 两列 Default — Editors & up
  - `/tmp/f03r4l4/ui2-dialog.png`：Configure 弹窗三组单选全部可见可选（ADD/DELETE：Creators & up / Editors & up / **Specific users** / Nobody；VISIBILITY：Viewers and up / Specific users / Everyone / Nobody），默认态正确（ADD/DELETE=Editors & up，VISIBILITY=Everyone）
- 本实例交互实测（owner 登录 → Tasks → Details → Permissions → Edit）：
  - 切 ADD → Specific users → 下拉选 f03r4l4-creator → Save → API GET /permissions 返回 `{TABLE_RECORD_ADD, granted_type:user, subjects:[us6zxdnt70hy39up(creator)]}` —— **UI 落库与所 selection 完全一致**（R3 dirty-flag + save 链路端到端验证）
  - grant 生效：editor insert → 403
  - console error 钩子 `window.__errs=[]`、Nuxt/vite error overlay `overlay=false` —— 双零
- 环境噪音：camoufox 多路并跑两次会话被踩崩（`Browser not launched`/launch exit 1），重开恢复；不影响结论

## 4. 质量门

- `cd packages/nocodb && npx tsc --noEmit` → **exit 0**
- `pnpm test`（jest Fork 桶）→ **Tests: 26 passed, 26 total**，exit 0（uniqueConstraintHelpers + baseVariableValidators 两套件）

## 5. 代码复审（diff 7b10716231^..HEAD 全量）

- checkPermission any-deny：AclMiddleware TABLE_VISIBILITY 门 `permissions.length && !hasTableVisibilityAccess` → 404 遮蔽；空 grant 列表 = 放行（fail-open 零开销）✓
- extract-ids ncTableId：主路径 `req.context.ncTableId = model.id`（~:236）+ v1 `:tableName` fallback（~:1110，`getByAliasOrId`）—— R1/R2 修复均在位 ✓
- ADD 门覆盖面：BaseModelSqlv2 单插/批量删/✕deleteAll/delByPk + insert.ts 单插/bulk（`skipPermissionCheck` 豁免 import/copy，且注释说明 row-independent 只查一次——性能修复点）✓；upsert 仅 `toInsert.length` 时查 ADD（拆分语义）✓
- 错误文案：`permissionDeniedMessage` 按 key 区分 create/delete record 文案，FIELD 保留 F02 文案；无内部信息泄漏 ✓
- console.log/debugger 残留：diff 新增行扫描为零 ✓
- [CE-EE] 标记：所有修改文件均有 ✓
- R1-R5 修复链（2f5a57b0d3 / 0a3e5fdab4 / c7a242cdf3 / b28787a54a）逐项在位 ✓

## 6. 回归 smoke（F02/F05/F07/F08/F10）

- F02：RECORD_FIELD_EDIT nobody → editor PATCH 403 / owner 200 / 删 grant 后 200 ✓
- F05：`POST /api/v2/meta/bases/:id/variables` `{key:"F03R4L4_VAR",value:"v1"}` → 200、list 200、删 200（key 强制 UPPER_SNAKE_CASE 为 F05 契约）✓
- F07：小 base（2 行）快照 create 200 → status=completed → restore 200 → 副本 base 出现 ✓（见 E3-2 大表限制）
- F08：`{"is_private":true}` 建 base → 200、GET 回读 is_private=true、非协作者 GET → 404（存在性掩蔽，F08 修复语义）✓
- F10：`POST /api/v2/meta/bases/:baseId/dashboards` → 200、删 200 ✓

## 7. E3 项（上游问题，不计 error）

1. **v1 bulkUpsert 纯 update 批 500**：afterUpdate BaseModelSqlv2.ts 上游 2023 代码；实测 owner 零 grant 同 500（t1 N 双基线），与本 fork 无关
2. **[新发现] duplicate/import 数据拷贝在单表 >1000 行时 job 失败**：`import.service.ts` chunk 刷写条件 `if (chunk.length > 1000)`（上游 a01380c73f 2023-05）可积到 1001 行，而 `bulkDataInsert` 入口上游校验 `validateV1V2DataPayloadLimit`（bulk-data-alias.service.ts:66，上游 sync 引入）按 `max(NC_GRID_MAX_SELECTION_LIMIT=1000, V1_V2_DATA_PAYLOAD_LIMIT=100)` 拒绝 → `Maximum 1000 entities are allowed per request`，JOB FAILED。实测：本 lane Tasks 表累积至 **1203 行**后快照 job 稳定 error（后端日志 3 次 JOB FAILED 同 error；≤600 行时同流程 completed）。双侧均上游代码，交互缺陷，非 fork F03/F07 引入。建议 backlog：刷写阈值改 `>=1000` 或 job 上下文豁免该校验
3. **duplicate 不复制成员角色**：`importUsers` = notImplemented（上游），副本仅 duplicator 有 owner 角色
4. **公开分享面不消费 TABLE_VISIBILITY**：sharedViewMeta 上游 CE 预埋面缺失（backlog ⑧，已有记录）
5. v1 按表 title 寻表 404：getByAliasOrId 上游行为（本次 v1 用例均走 id 路径，未受影响）

## 8. 环境事件（非产品 error，供 orchestrator 知悉）

1. **并发他路批量降权**：约 07:39-07:57 有他路将全库测试账号 `nc_users_v2.roles` 批量改为 `org-level-viewer`（l1/l2/l4/l5 全中），叠加我方账号 `workspace_user.roles=workspace-level-no-access`（9-15 11:17 即如此）导致 baseCreate 403。恢复：经 super 账号（f03r3-owner，R3 同 lane 遗留，凭据在 .work/ee-ce/r3-lane4/env.sh）PATCH /api/v1/users/:userId 回 org-level-creator，并将我方两 owner 的 workspace 行改 workspace-level-creator（直接 SQL，nocodb-dev）。**我方账号现已为健康的 creator 态**
2. 后端偶发瞬时连接失败（HTTP:000，秒级恢复，重试即过）；org 角色变更会 bump token_version 使旧 JWT 401（测试脚本已改为按需重登）
3. camoufox 多路互踩致 2 次会话崩溃，重开恢复
4. 清理：本 lane grants/snapshots/表单视图/foreign base/duplicate 副本/T9 测试 base 已全部删除；「f03r4l4 Base」主 fixture（Tasks 1203 行测试数据）保留供后续轮次复用——注意 E3-2：行数 >1000 会触发快照/带数据 duplicate 失败，后续轮次若测快照建议先清行

## 附录 A：实测证据索引

- 脚本：/tmp/f03r4l4/{env,bootstrap,t1_matrix,t2_visibility,t3_validation,t4_form_dup_perf,t5_regression}.sh（可重跑复现）
- 输出：t1 46/46、t2 23/23、t3 34/34、t4 12/12、t5 10/10（全部 OK，无 FAIL）
- 截图：/tmp/f03r4l4/ui1-permissions-tab.png、ui2-dialog.png（ui3-final.png 为会话失效后的登录页，不作证据）

## 附录 B：前实例遗留脚本缺陷（已修复，均非产品问题）

1. t1 行查找用 `?limit=50`（表已 580+ 行，新插行不在窗口）→ 改 `?limit=1&sort=-Id`
2. t1 O 段末项期望 403，但彼时唯一 grant 已删、零 grant = fail-open 200（与规格一致）→ 期望改 200
3. t4 建表单视图用不存在的 `POST /api/v2/meta/tables/:id/views` → 正确路由 `POST /api/v2/meta/tables/:id/forms`
4. t4 公开提交用旧路径 `/api/v1/db/public/data/noco/:uuid`（404）→ `POST /api/v2/public/shared-view/:uuid/rows` + `{"data":{...}}`
5. t4 duplicate 取 `.id`（job id）→ 应取 `.base_id`
6. t4 计时用 `date +%s%3N`（BSD date 不支持，输出含字面 N 致算术错）→ perl Time::HiRes
7. t4/t5 addgr 缺 granted_role 形参、t5 F05 用 `name`（应 `key`）、F07 假设 `{list:[]}`（实为裸数组）、F08 用 `type:"private"`（应 `is_private:boolean`）、F10 用 `/api/v2/meta/dashboards`（应 base 子资源路由）
