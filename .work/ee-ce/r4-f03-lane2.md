# R4 F03 Data permissions — lane 2 审查报告（重试实例）

**PASS（0 error）**

- 审查对象：HEAD main（ee85ce82c8 + patrol commits，F03 实现 7b10716231 + R1/R2/R3 修复链 2f5a57b0d3/0a3e5fdab4/c7a242cdf3/b28787a54a），工作树与运行副本（/Users/kamasylvia/.nocodb-run，bundle 22:21 编译 > R3 commit 11:08）三关键文件 diff 逐字节一致（import.service.ts / export.service.ts / duplicate.processor.ts 均 IDENTICAL）——API 实测跑的就是当前代码。
- 接管说明：前实例完成 t0-t3 与 UI 截图，t4 断连中断；测试输出未落盘，故 t1-t5 全部重跑取证（脚本幂等，自带残留清理）。质量门 jest 引用前实例落盘 log（代码零变更），tsc 本实例重跑。
- 账号/资产清理：grants/snapshots/dashboards/variables 已清空，测试 base 全部删除（见「清理记录」）。

## issues 列表

**0 项。**

## 观察项（不计 error，供 orchestrator 裁决归档）

1. `packages/nc-gui/components/dlg/Table/Permissions.vue:save` — UI 端「user 型选人 → Save → DB 落库」未拿到直接 DB 确证：两次尝试均撞上后端自愈重启窗口（save 请求发出后 token 全量失效/浏览器会话被 camoufox 多路互踩杀掉）。间接证据充分：① save 走 `POST /api/v2/meta/bases/:id/permissions`（buildPayload 已审，line 250-262），该端点 user 型创建在 t1/t3/t4 API 实测 3 处独立验证（创建 200 + subjects 落库 + enforcement 生效）；② 空选点 Save 的 R3 校验实测生效（见 R3 段 ⑤）。建议：下轮或修复轮单独补一次 UI save→DB 断言（选后端静默窗口执行）。

## 实测证据

### 1. 集成矩阵（重跑，输出 /tmp/f03r4l2/logs/t1.out，38 PASS / 0 FAIL）

- TABLE_RECORD_ADD：nobody/role:creator/user:editor × v2 单条/bulk × editor/creator/owner 全符合；update 与 ADD 正交（ADD nobody 时 update 200）；删 grant 下一请求放行（fail-open 往返 200）。
- TABLE_RECORD_DELETE：v2 单删/批量删/deleteAll × 403/200 全符合；v1 单删/bulk 删 403；owner 直通 200；插入正交 200。
- multi-grant any-deny：ADD(nobody)+DELETE(role:creator) 并存 → editor insert 403、creator delete 403、editor delete 403，方向正确。
- bulkUpsert 拆分：纯 update 批（无 ADD grant）放行至 afterUpdate（500 = 已知 E3 owner 同炸）；混合批（含插入行）403。
- patch 切换 granted_type 全部 200 且 enforcement 即时生效。

### 2. TABLE_VISIBILITY（重跑 t2 18 PASS + 表单段复验 t2b 5 PASS / 0 FAIL）

- meta get / v2 data / v1 data / count / aggregate 对 editor 全 404 遮蔽（owner 200）；表列表对 editor 隐藏 t_other、owner 可见。
- role:viewer 档：editor+viewer 200（viewers-and-up 语义）；user:editor 精确匹配（viewer 404）；删 grant = Everyone 往返（viewer 200）。
- 公开表单 enforce_for_form：t2 首跑 3 FAIL（share form 404 连锁）为瞬态——同请求单跑复验：share meta 200、无 grant 匿名 insert 200、enforce_for_form=true 匿名 403、=false 匿名 200、patch 往返 200（/tmp/f03r4l2/logs/t2b.out）。瞬态成因：该窗口内他路触发 rspack 重编译（本审查期间至少 3 次后端重启，有 token 失效记录）。

### 3. 校验对称（重跑 t3 18 PASS / 0 FAIL）

- create：nobody+subjects 400、role 缺 granted_role 400、user 缺 subjects 400、非法 granted_type/granted_role 400、低于 minimumRole 400、重复键 400、跨 base 表 id 400、field 键用于 table 400。
- update：nobody+subjects 400、nobody→role 无 granted_role 400（复活守卫）、nobody→role:owner+subjects 200、→user 无 subjects（无继承）400、granted_role=null 400。
- 非 owner 建 grant 403。

### 4. R3 修复回归（重跑 t4 13 PASS + DB 级补证）

- ① nobody 转换清 granted_role：DB/API 双证 granted_role=NULL ✓
- ② 复活守卫：nobody→role 不带 granted_role → 400 ✓
- ③ user→role 切换清 subjects：subjects 1→0 ✓
- ④ bulk 性能：100 行 creator 无 grant 511ms vs 带 grant 914ms（ratio 1.7，无逐行 Permission.list）✓
- ⑤ UI 空选校验：弹窗切 Specific users 不选人点 Save → 保存整体中止、弹窗保持打开、无 grant 写入、状态重拉回 API 真实态（editors_and_up/everyone）✓
- ⑥ **duplicate/restore 带 grants（功能 PASS，DB 级四副本交叉验证）**：
  - snapshot 副本 p32768a49wlluxh 带 table VIS nobody grant（snapshot create 路径带出）；
  - duplicate 副本 p7izujw3h38jnc3/copy_2：table VIS entity_id=mwn2771d69iwvye = 该副本自身 t_other（id 重映射正确）；
  - duplicate 副本 pk8oy64xh8muv8p/copy_3：field user 型 grant subjects 保留（subject_id=usjhubr961rmd1mp）；
  - restore 产物 pp4rfhiwsk13r8c：带 TABLE_VISIBILITY nobody，entity_id=mmb38j54ivx3djt = 副本自身 t_other ✓；
  - enforce 复验：editor 访问副本受限表 404。
  - 代码链路三段全审在位：export.service.ts:724-754 序列化（excludePermissions 默认 false、per-model 过滤 table+field）、import.service.ts:173-209 importPermissions（entity_id 经 getIdOrExternalId 重映射、subjects 过滤 user 型、逐 grant try/catch 容错）、importModels:2014-2022 调用点（existingModel 跳过）。

### 5. 代码复审（git diff 7b10716231^..HEAD，15 文件 +738/-43）

- checkPermission（BaseModelSqlv2.ts:10602-10750）：owner 直通、req.context 挂载防实例缓存 stale、空列表 fail-open、逐 grant any-deny、匿名 form 上下文 honour enforce_for_form ✓
- enforcement 挂点全覆盖：insert.ts 单插/bulk（bulk 只查一次，skipPermissionCheck 豁免 import/copy）、v1 insert+public form（isFormContext）、delByPk、bulkDelete、deleteAll、bulkUpsert toInsert 才查 ADD ✓
- extract-ids（R2 c7a242cdf3）：主路径 Model.get 分支设 req.context.ncTableId（覆盖 v1 :baseName/:tableName 家族）+ legacyExtractIds tableName alias fallback；AclMiddleware VISIBILITY gate 404 遮蔽、service user 豁免、空 grant 零开销 fail-open ✓
- permissions.service.ts：F02 的「table 键拒绝」守卫替换为三 table key 白名单 + 跨 base 表校验 + synced 表拒绝 ✓
- 错误文案：permissionDeniedMessage 按 key 分文案，label 用表 title/列 title（用户可见值），无内部 id/路径泄漏 ✓
- 无 console.log/debugger 残留；[CE-EE] 标记 21 处；useEeConfig gate（blockTableAndFieldPermissions）替换 isEeUI 硬编码 ✓

### 6. 功能回归（重跑 t5 全 PASS）

- F02：field grant nobody → editor update 403 / owner 200 / 删 grant → 200 往返 ✓
- F05：variable create/list 200 + delete ✓
- F07：snapshot create 200、list 200、restore 200（restore 产物带 grants 见 §4⑥）✓
- F08：private base create 200，is_private=true（duplicate 继承 is_private 的 F08 R1 修复同时在位）✓
- F10：dashboard create/list 200 ✓

### 7. UI 段（camoufox 独立会话，:3000）

- owner 登录 → base → t_main → 侧栏节点 ⋯ 菜单（testid nc-sidebar-table-context-menu）→ Edit table permissions（testid sidebar-table-permissions-t_main）→ 弹窗打开 ✓
- 弹窗三组单选齐全：ADD（Creators & up / Editors & up / Specific users / Select users / Nobody）、DELETE（同）、Table Visibility（Viewers and up / Specific users / Everyone / Nobody）——Specific users 选项可见可选（R1 死代码移除后正常渲染）✓
- 默认态与 API grants 一致：无 grant 时 ADD/DELETE=editors_and_up、VISIBILITY=everyone（与 loadCurrent 代码语义一致，实测两次打开均如此）✓
- 切 Specific users → 下拉搜索 "f03r4l2" → 真实 CDP click 选中 editor（users 区 tag 显示）✓（Save→DB 确证受环境所限，见观察项 1）
- console error / Nuxt error overlay：本会话内未出现（多次全页 innerText 检查无 error overlay DOM）✓

### 8. 质量门

- `npx tsc --noEmit`：exit 0（本实例重跑）
- `pnpm test`：26/26 PASS（前实例落盘 /tmp/f03r4l2/jest.log，jest_exit=0，771s；自那以后 packages/ 下代码零变更——git status 干净，HEAD 未动）

## E3 项（有诊断证据，不计 error）

1. **duplicate-base job 间歇性 failed（多 base 通用，先于 permissions 逻辑）**
   - 现象：POST duplicate 返回 job，job 最终 status=failed；失败副本 base **0 表 0 grant**（nc_models_v2 / nc_permissions 双查），失败发生在表创建之前，与 F03 grants 无任何交集（grants import 位于表创建之后）。
   - 证据链：① 本实例两次失败（job5k8qxftyu95491 07:35、jobiq2t67o3sjl62k 07:48，源 base pvsux6iiyvvgfhn 均带 grants）；② **同一 base 带同样 grants 在 00:21:46/00:23:02 两次 completed 且 grants 带出正确**（jobkdu6d02isn2yeq、jobxrowr3gbr6l3hz）；③ nc_jobs 近 24h 内 failed/completed 跨至少 6 个不同 base 混杂（p7eh9e5ai2t9pht、pj8svso4u79sde4、pnx2z185wm4xrqz、pyc6khjcwwmkrfx、puwo616k6ev81qm 等也 failed，非本 lane base）；④ completed 副本 4 个独立验证 grants 带出（§4⑥）。
   - 判定：多 lane 并发压测下的间歇环境问题（fallback 队列 concurrency=2 + 多路同时投 duplicate job），非 F03 引入、非 grants 相关。影响：偶发 snapshot create 显示 error 状态。建议 coordinator 记 backlog：错峰单跑验证 job 稳定性。
2. v1 bulkUpsert 纯 update 批 500（BaseModelSqlv2.ts afterUpdate，上游 2023 代码，owner 零 grant 同炸）——t1 实测复现 500。
3. v1 按表 title 寻表 404（getByAliasOrId 上游行为）。
4. 公开分享面（sharedViewMeta）不消费 TABLE_VISIBILITY（上游 CE 预埋面缺失，backlog ⑧）。
5. 后端自愈脚本频繁重启 :8080（本审查窗口 ≥3 次：token_version 失效致旧 token 全 401、一次 UI save 确证被打断），属流程/环境噪音，非产品问题。

## 清理记录

- grants：源 base 清空（GET permissions = []）
- snapshots：3 个全删（200）
- dashboards：3 个全删（200）；variables：0 残留
- bases 删除：p0rgfrl78rkguyt、pp4rfhiwsk13r8c、px5h1cnmo2nm5td、pyutyv55mig385i、pn03cxzk6ejv55j、p7izujw3h38jnc3、pk8oy64xh8muv8p、p3wbt6juqm1m97q、pf19nlg2596d1az、pb4jq9r3xp6xl4n（全部 200；pwxq2squ8c0nclo 已被 t4b 自删，404 属预期）
- 残留：仅源 base pvsux6iiyvvgfhn 本体（含测试表与行数据，无 grants）；f03r4l2-* 测试账号未删（无强制要求）

## 测试脚本与日志

- 脚本：/tmp/f03r4l2/t0-setup.sh、t1-matrix.sh、t2-visibility.sh、t2b-form.sh、t3-validation.sh、t4-r3fix.sh、t4b-dup.sh、t5-regression.sh、dbq.sh（DB 只读查询）
- 日志：/tmp/f03r4l2/logs/{t1,t2,t2b,t3,t4,t4b,t5}.out、jest.log、tsc.log；截图 r4-ui-dialog-default.png、r4-ui-user-selected.png（前实例 3 张 ui*.png 同目录）
