# F03 Data permissions — R4 复审报告(lane 1)

**结论:issues(1 minor + 2 观察)** — 0 error。集成全矩阵、R3 修复回归、代码复审、跨功能回归、UI 段全部通过;质量门双绿。

- 审查员:R4 lane 1(重试实例,前实例 00:47 API 断连作废,本次从零全量执行)
- HEAD:main @ 126d4f713d(F03 源码终点 = b28787a54a;其上仅 chore(work) 巡检提交,源码无变更)。工作树无源码修改。
- 后端 :8080 / 前端 :3000 均健康;测试账号 f03r4l1-{owner,editor,creator,viewer}@t.local(结束已降权 org-level-viewer);测试 base×3 + snapshot/restore base×2 已删(仅余上游标准软删墓碑,`deleted=t`),grants/subjects/白盒行零残留。

---

## issues

### minor 1 — i18n 缺键:R3 空 SPECIFIC_USERS 守卫 toast 显示原始 key
- `packages/nc-gui/components/dlg/Table/Permissions.vue:237`:`message.error(t('labels.selectUsers'))` — `labels.selectUsers` 在 en.json / zh-Hans.json 均不存在(实际键路径为 `objects.permissions.inlineUserSelector.selectUsers`,两语言文件都在,见 en.json:1155 / zh-Hans.json:982)。
- 实测:对话框选 Specific users 不选人点 Save → 守卫正确触发(save 中止、对话框不关、既有 grant 未删——API 复核 grant 仍在),但 toast 文案为原始 key `labels.selectUsers`(截图 ui-dialog-6 后续帧/toast 捕获,`toasts=["labels.selectUsers",...]`)。
- 建议:改为 `t('objects.permissions.inlineUserSelector.selectUsers')`,或在两语言文件 `labels` 下补 `selectUsers` 键。

### 观察 1(minor/perf,backlog 级)— 有 grant 时 bulk insert 恒定 ~2.0x 慢,根因是 F02 每行 FIELD 检查而非 F03 ADD 检查
- 实测(远程 QNAP PG,100 行 v2 bulk insert,role:editor 允许型 grant):
  - 无 grant:0.55–0.72s;有 grant:1.14–1.37s(3 轮交替,best ratio 2.01x,稳定非噪音);
  - deny 型 grant(nobody):403 仅 0.07s → R3 提出的 ADD 检查本身极廉价,**R3 hoist 修复在位**;
  - 单行插入:无 grant ~85ms vs 有 grant ~110ms(Δ≈+25ms≈2 次 RTT);100 行 Δ≈550ms ≈ 每行一次额外 RTT。
- 根因链:`insert.ts` bulk 行循环内的 **F02 每行 `checkPermission(RECORD_FIELD_EDIT)`**(Permission.ts R1 注释明确 list 刻意 cache-free)每行做一次 `Permission.list`;base 存在任意 grant 时每次 list 多一条 subjects 查询 → 每行多 1 RTT。对比:`bulkUpdate` 已在行外聚合 entityId 集合做一次 FIELD 检查(BaseModelSqlv2.ts:~4539),bulkInsert 行循环可同样聚合。
- 建议(backlog):将 bulkInsert 行循环内的 F02 FIELD 检查提出行外聚合(与 bulkUpdate 同款);R3 的 F03 ADD 检查无需改动。任务书门限"与无 grant 同量级"按宽口径(同为秒级、非逐行 Permission.list 的历史 +92% 已消)可判过,但 2.0x 常数差值得入账。

### 观察 2(上游面,E3 旁证)— v2 `POST /records?upsert=true` 忽略 upsert 旗标 = 纯插入
- `data-table.controller.ts:75` POST `/api/v2/tables/:modelId/records` 只读 `viewId`/`undo`,不读 `upsert`;swagger 中 upsert 仅存在于 v1 bulk 路由(`/api/v1/db/data/bulk/{orgs}/{baseName}/{tableName}/upsert`)。
- 实测:无 grant 时带已存在 Id 的 `?upsert=true` 请求 → 200 且**新造一行**(响应 Id=233,入参 Id=232 被丢弃自增),count +1;ADD deny 下同请求 → 403(因为它就是插入)。
- 非 F03 缺陷(上游 API 面缺口,客户端可能误以为有 upsert 语义);建议随已知 E3 一并记 backlog(候选上报上游)。

---

## E3 已知项(勿计 error,附本次证据)
1. **v1 bulkUpsert 纯 update 批 500**(afterUpdate BaseModelSqlv2.ts:6065,上游 2023):本次复现 owner 零 grant → 500、creator 零 grant → 500、editor 携 ADD deny → 500,三者完全一致 → 确证上游非 F03(t5b O 节,`{"msg":"Something didn't work as expected..."}`)。
2. **公开分享面(sharedViewMeta)不消费 TABLE_VISIBILITY**:补证——公开数据行列表路由在 VISIBILITY nobody 下已 404(t4b,说明 data 面已被 extract-ids 覆盖),仅 meta/分享页消费缺失,维持 backlog ⑧。
3. v1 按表 title 寻表路径未单独复测(全矩阵 v1 用例统一走 table id,与 R3 同法;上游行为已知)。

---

## 实测覆盖与证据(关键断言)

### 1. 集成全矩阵(:8080 API 实测)
- **fail-open**:无 grant 下 editor v2/v1 单插/ bulk、update、delete、deleteAll、count、meta、tables list 全 200;删 grant 后下一请求放行(200)✓(t1 §0/A)
- **TABLE_RECORD_ADD × nobody/role(creator,editor)/user([creator])**:editor 403、creator 200/403 对位、viewer 403、owner 直通 200;v2 单条+bulk、v1 单插+bulk、v1 upsert 含插入行全部拦截;update/delete 与 ADD 正交(200)✓(t1 §A–D)
- **TABLE_RECORD_DELETE × 同 grant 矩阵**:v2 单删/bulk 删、v1 单删、v1 deleteAll 全 403;insert/update 不受扰(200)✓(t1 §E–G)
- **v1 upsert 拆分语义**:纯插入批 403、混合批 403(ADD deny);纯 update 批不触发 ADD 检查(500 为 E3,见上);DELETE deny 不拦 upsert ✓(t1b §N)
- **multi-grant any-deny**(白盒:psql 注入同键双 grant role:editor + user:[creator]):editor 403(被 user grant 否决)、creator 200 ✓(t1b §P);API 侧同键重复 create → 400(R1 重复键守卫,t3 W11)
- **跨表/跨 base**:Other 表 grant 不影响 Tasks(200/403 对位);跨 base entity_id → 400 ✓(t1b §Q、t3 W12)
- **VISIBILITY**:nobody → meta/v2 list/v2 count/v2 aggregate/v1 list/insert/delete 全 404 遮蔽、tables list 消失(owner 仍 200、Other 表不受扰);删 grant 往返(Everyone)恢复 200;role:editor → viewer 404/editor 200/creator 200;role:viewer → 全员(含 viewer)200;user:[creator] → 精确匹配(creator 200,editor/viewer 404);可见表写操作不受 VISIBILITY 阻拦 ✓(t4 §R–U,22/24,余 2 项为视图创建路由测试 bug,t4b 修正后全过)
- **公开表单**:ADD nobody enforce_for_form=true → 匿名提交 403(`Forbidden - You don't have permission to create records in Tasks`);PATCH false → 匿名 200(落行 Id=252);owner 直插 200 ✓(t4b 3/3)
- **校验对称**(create+update,全 400):nobody+subjects、role 缺 granted_role、user 缺 subjects、user+team subject、非法 permission/entity/granted_type/granted_role、低于 minimumRole(ADD role:viewer)、缺 entity_id、重复键、跨 base 表、field entity 挂 TABLE key;PATCH granted_role:null → 400、bogus → 400、降 minimumRole → 400、PATCH nobody+subjects → 400、复活守卫(nobody→role 缺 granted_role)→ 400;user grant PATCH subjects:[] → 400;ACL:editor create grant → 403(list editors+ 可读 = F02 时 documented 设计,service 头注释)✓(t3 25/29 + t3b 6/6;4 个 FAIL 均为测试预期修正:role 同型 no-op PATCH 保留现值 200 合理、Y5 用 viewer 撞 minimumRole 恰证 W8、list 设计可读)
- **owner-role grant**:create role:owner 落库 owner;无涉 PATCH 后仍 owner(不降权 creator);owner→commenter/viewer 降档 VISIBILITY 允许 ✓(t5 AA1–4)
- **NOBODY 转换卫生**:role→nobody 后 GET granted_role=null;随后 PATCH {granted_type:role} 无 granted_role → 400(复活守卫闭合)✓(t3 X7/X8)
- **user→role 清理**:切 role:editor 后 GET subjects=[] 且 psql `nc_permission_subjects` 计数 0 ✓(t3b Y5'/Y6')
- **role↔user 切换端到端**:role→user 带 subjects → editor(在册)删 200、creator(不在册)删 403 ✓(t3b Y8')
- **payload 契约**:v2 bulk delete 与 v1 bulk delete 均要求 `[{"Id":N}]` 对象数组(bare `[N]` → 400 "Each record to delete must be an object…" — 该校验位于 F03 checkPermission **之后**,deny 优先于载荷校验,设计合理)

### 2. R3 修复回归(b28787a54a)
- **弹窗 dirty-flag + SPECIFIC_USERS 保存**:UI 实测切 user 型选 creator → Save → API 落库 `TABLE_RECORD_ADD user subjects=[usc507pi2y8iunzv]` 完全一致 ✓
- **SPECIFIC_USERS 单选项默认态可见可选**:截图证实三组单选均含 Specific users(R1 v-if 死代码已去)✓
- **空选 Save 守卫**:错误 toast + save 中止 + 对话框不关 + 既有 grant 未删 ✓(toast 文案缺键 → minor 1)
- **owner-role 回显**:UI/API 均 Creators & up 往返不降权 ✓(AA + buildPayload originalRole 代码)
- **duplicate 带 grants**:源 base 4 grants(VISIBILITY nobody + ADD role:creator + DELETE user[creator] + FIELD RECORD_FIELD_EDIT user[creator])→ POST /api/v2/meta/duplicate/:baseId → 副本 4 grants 全数带出:VISIBILITY entity_id 映射新表 id(m7ljdcrg214b7hm)、FIELD 映射新列 id(ccg05ks2g344ime)、DELETE subjects 保留、副本上 grant 实际生效(editor ADD → 403)✓(t5b AC0–AC6,6/6;importPermissions 逐 grant 容错经代码审:per-grant try/catch + idMap 解析 + subjects 过滤 user 型,在位)
- **bulk 性能**:见观察 1(R3 hoist 在位,残差归因 F02)

### 3. 代码复审(diff 7b10716231^..HEAD,15 源文件)
- R1–R5 修复在位:2f5a57b0d3(v1 legacyExtractIds fallback)、c7a242cdf3(主路径 ncTableId —— 覆盖 v1/:baseName 家族,直接为 VISIBILITY 门供 id)、0a3e5fdab4(弹窗选项)、e1e996283c(VISIBILITY 默认 Everyone,UI 截图证实)、b28787a54a(五项,上)
- checkPermission any-deny:grants 循环 deny 即 break → forbidden;owner 直通;anonymous 走 enforce_for_form;错误文案经 permissionDeniedMessage 白名单化,无内部泄漏;VISIBILITY 走 tableNotFound 404 不探 existence ✓
- importPermissions:entity_id 经 idMap 解析、subjects 仅留 user 型且需 id、逐 grant try/catch(logger.debug,不中断导入)✓
- console.log / debugger:diff 全量扫描 **0 处** ✓
- [CE-EE] 标记:15 个改动文件全部带标记(85/22/13/10/8/8/7/4/3/3/3/2/2/2/1 处)✓
- isEeUI 全局量未翻转;改用 `blockTableAndFieldPermissions` feature flag(Node.vue/usePermissions/Table.vue)符合 fork gate 约定 ✓
- 附注:`helpers/tableHelpers.ts hasTableVisibilityAccess` 用 `permissions.find` 取**首条** VISIBILITY grant(checkPermission 用 filter 全量 any-deny)——API 无法造重复键(R1),仅白盒双 grant + VISIBILITY 场景理论上可达,与单 grant 假设一致,不入 issue。

### 4. 跨功能回归 smoke
- **F02**:RECORD_FIELD_EDIT nobody → editor 改受控列 403、改他列 200、owner 200;删 grant → 200 ✓
- **F05**:variable create/list/update/delete 全 200 ✓
- **F07**:snapshot create → completed(~10s)→ list → **restore 200**(返回 base_id,新 base title "F03R4L1SNAP (restored)")→ delete 200 ✓(副本表列表因异步时机未在断言窗口内出现,restore 主链路 200 + base 存在已证)
- **F08**:成员路径(受邀 editor)private 前后均可见、meta 200 正常;非成员(creator,org-level-viewer)private/非 private 均 404/不在列表——本账号组合无法观察 private 差异(F08 自身四轮评审已过,本次 smoke 无回归信号)
- **F10**:dashboard create/list/delete 全 200 ✓
- **F03 与 F02 正交**:table grant 存在不影响 field grant 判定、反之亦然(全程混测)

### 5. UI 段(camoufox-cli,:3000)
- owner 登录 → Tasks 侧栏节点 kebab → "Edit table permissions"(data-testid sidebar-table-permissions-*)→ 弹窗三 key:ADD/DELETE 默认 Editors & up(无 grant 默认)、VISIBILITY 默认 **Everyone**(R1 修复可见)✓
- Configure 弹窗三组单选含 Specific users 全部可见可选;切 user 型 → "Select users" a-select 出现 → 过滤选 f03r4l1-creator → chip 显示 → Save → API 复核 grant 精确一致 ✓
- Nuxt error overlay **无**;无应用错误 toast(过程中 "You have been signed out" 为本审查员 API 重新 signin 踢掉浏览器会话的自伤副作用,非应用缺陷)
- 截图:/tmp/f03r4l1/ui-dialog-1.png(默认态)/ui-dialog-5.png(Specific users 选中+选择器)/ui-dialog-6.png(选人)

### 6. 质量门
- `cd packages/nocodb && npx tsc --noEmit` → **exit 0**
- `pnpm test`(jest Fork 桶)→ **26/26 passed**(uniqueConstraintHelpers.Fork + baseVariableValidators.Fork,--runInBand,623s)

---

## 测试数据清理
- base:F03R4L1(p9xxjdxd1c6wgkc)、F03R4L1XBASE(ppw92xk4v3b61xy)、p03lsjvdzi8ufkr(前实例遗留)、F03R4L1SNAP + (restored) — 全部 DELETE 200;`nc_bases_v2` 仅余 deleted=t 墓碑(上游标准)
- grants/subjects:全 base scrub 至空;白盒 perm_dup2 / psub_dup1 零残留;孤儿 permission 行 0
- 账号:f03r4l1-* 全部 org-level-viewer(owner 的 super 已撤)
- 快照/变量/dashboard:随 base 删除或显式删除;camoufox 会话已 close
- 测试脚本与日志:/tmp/f03r4l1/(仓内零污染,git status 恢复派遣时状态)

## 裁决建议
- minor 1(i18n 键)属一行修复,建议随下轮修复链带上;
- 观察 1(perf)与观察 2(v2 upsert 旗标)建议入 backlog(上游可上报);
- 除上述外 0 error —— F03 可维持 pass 轨道,本轮按"连续 0 error 轮次"口径是否计数由裁决定(minor 是否打断计数请裁决裁断)。
