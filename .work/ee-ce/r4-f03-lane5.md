# R4 F03 Data permissions — Lane 5 审查报告（重试实例）

**结论：issues（2 项）** — 1 error（UI Specific users 分页缺陷）+ 1 minor（i18n key 错误）。后端全矩阵 API 实测零 error，质量门双过。

- 审查员：lane 5（重试实例，接管前实例遗留的 /tmp/r4l5-t1~t5*.sh；脚本重跑 + 逐段手工补验，未引用任何他路结论）
- 时间：2026-09-16 00:30–01:40
- 环境：后端 :8080（内盘副本 ~/.nocodb-run，已验证与 UNITEK 仓 HEAD 全部 13 个 F03 相关文件逐字节一致）；前端 :3000；测试账号 f03r4l5-*；head 126d4f713d（F03 链 ee85ce82c8 + R3 修复 b28787a54a，之上仅 chore(work) 提交）

---

## Issues

### 1.（error）弹窗 Specific users 选择器分页缺陷 — 多用户环境无法选到目标用户

- `packages/nc-gui/components/dlg/Table/Permissions.vue:69-83`（loadMembers）
- 问题：`loadMembers` 调 `basesStore.getBaseUsers({ baseId, force: true })` 不带 `searchText`/分页参数；后端 `GET /api/v2/meta/bases/:baseId/users` 默认分页仅返回前 8 条（实测 totalRows=726，dev 库全站 workspace 用户均在其列）。超过一页时，`members` 只含第一页 8 人，**不在首页的目标用户在 UI 中永久不可选**。
- 实测证据：干净独立 session（lane5ui）打开 Configure 弹窗 → ADD 切 Specific users → 打开下拉 → `.ant-select-item-option` 恰 8 项（r3cb/r2c/r1a/f05r4b…，按注册序），base collaborator `f03r4l5-user1@t.local` 不在列表，无法选择；下拉无搜索输入框，用户无自救手段。
- 波及：F03 表弹窗同文件；F02 字段弹窗 `packages/nc-gui/components/dlg/Field/Permissions.vue:46-52` 为同款 loadMembers 模式，同样受影响（回归风险）。
- 建议：loadMembers 循环翻页取全（pageInfo.totalRows）或给 a-select 启用搜索并透传 searchText 至 `getBaseUsers`；两个弹窗一并修。

### 2.（minor）保存前置校验报错 toast 显示 i18n 裸 key

- `packages/nc-gui/components/dlg/Table/Permissions.vue:237`
- 问题：`message.error(t('labels.selectUsers'))` —— `labels.selectUsers` 键不存在；实际键为 `objects.permissions.inlineUserSelector.selectUsers`（en.json:1155 / zh-Hans.json:982）。SPECIFIC_USERS 空选点 Save 时 toast 文案显示裸字符串 "labels.selectUsers"。
- 实测证据：UI 空选点 Save → save 全程中止（dialog 未关、无 API 写入、既有 grant 未被删——行为正确）+ toast 文本 "labels.selectUsers"。
- 建议：改为 `t('objects.permissions.inlineUserSelector.selectUsers')`。

---

## 实测证据（关键断言，method/path → 状态码）

### A. fail-open / 直通 / 删 grant 放行
- v2 POST /tables/:id/records editor 零 grant → 200；DELETE 同 → 200
- 建 ADD nobody 后：editor insert → 403；owner → 200；editor delete（仅 ADD grant）→ 200（正交）；creator → 403；PATCH update → 200（正交）
- 删 grant 后 editor insert → 200（fail-open 往返）

### B. ADD/DELETE 全路由
- v1 POST/DELETE /v1/:baseId/:tableId(id) editor → 403 / owner → 200（R1/R2 修复的 v1 主路径生效）
- v2 数组 bulk insert editor（ADD nobody）→ 403 / owner → 200
- v2 bulkDelete editor → 403 / owner → 200；v2 deleteAll editor → 403
- v1 upsert：insert-only editor → 403；insert creator（ADD role:creator）→ 201；pure-update → 见 E3①
- 100 行 bulk：无 grant 195ms / 有 role grant 139ms（同量级，R3 批量性能修复在位）

### C. user 精确匹配 + any-deny（手工重验，t2 E 段脚本与 D 段 grant 唯一键冲突）
- ADD user:usa7g5gtz1x9waqs：U1 insert → 200；creator → 403；editor → 403；owner → 200；删 grant 后 creator → 200

### D. VISIBILITY（含层级档语义）
- role:commenter：viewer meta → 404（power 2<3）；editor meta → 200（4≥3）；viewer data(v1+v2)/count/aggregate → 404×4；删 grant 后 viewer → 200
- role:viewer：viewer → 200；表列表 editor 含 1 / outsider 含 0；outsider（无 base 角色）meta → 403（base ACL 先于表级，不泄露存在性）
- VIS nobody（残留态意外验证）：viewer/editor meta 全 404、editor 表列表含 0 — nobody 全拒语义 ✓
- SDK 语义佐证：`PermissionRolePower` 层级比较（nocodb-sdk permission/index.ts:366-377），UI 文案 "Viewers and up" 一致

### E. 公开表单 enforce_for_form（正确语义 = ADD grant 的开关）
- ADD nobody eff=true：匿名 submit → 403（v1+v2 双路径）；eff=false → 200；无 grant → 200；DB 侧仅 eff=false 后的行入库
- 注：TABLE_VISIBILITY grant 的 enforce_for_form 全仓无消费点（VISIBILITY 为读权限，写路径 checkPermission 仅消费 TABLE_RECORD_ADD/RECORD_FIELD_EDIT），VIS+eff 组合为死配置——观察项，非 error（默认 true，无安全影响）

### F. 校验对称（create + update）
- 400 全过：nobody+subjects、role 缺 granted_role、user 缺 subjects、非法 granted_type/granted_role、非法 permission key、field entity 上 ADD、cross-base 表、duplicate (entity,entity_id,permission) 键、update 侧同款
- minimumRole 真低于：ADD role:viewer → 400；DELETE role:viewer → 400（消息 "granted_role viewer is below the minimum role…"，无内部泄漏）；role:editor（==min）→ 200 合法

### G. R3 修复回归（逐项实测）
- NOBODY 转换：PATCH role:creator → 200；PATCH nobody → granted_role NULL（GET 验证）✓
- 复活守卫：PATCH {granted_type:role} 无 granted_role → 400 ✓
- user→role 切换：subjects 由 [usa7g5gtz1x9waqs] → 0 ✓
- owner 回显往返（干净 UI session）：API 建 role:owner → 弹窗 ADD 回显 Creators & up → 切 Editors 再回 Creators → Save → API granted_role 仍 owner（不降权）✓
- SPECIFIC_USERS 空选 Save：中止 + 报错 toast（不删既有 grant）✓（toast 文案裸 key 见 issue 2）
- duplicate 带 grants（干净重测）：src 建 VIS nobody + ADD user:U1 + FIELD user:U1 → duplicate → 副本三 grant 全带出，VIS/ADD entity_id 映射新表 id、FIELD 映射新列 id、subjects 保留 U1；副本上 VIS nobody 生效（creator meta 404 遮蔽，先于 ADD 403——不可见表不泄露存在性）
- importPermissions 代码审：id 映射 getIdOrExternalId、subjects 过滤仅 user、逐 grant try/catch 容错、entityId 空跳过（import.service.ts:173-208）✓

### H. 回归 smoke
- F02：FIELD user grant → creator edit 403 / owner 200 / 删 grant 后 200 ✓
- F05：variables list/create(key UPPER_SNAKE_CASE)/delete → 200 ✓
- F07：snapshot create → completed → restore 200（产物 "(restored)" base 落 trash 语义）✓
- F08：v3 base create/GET/delete → 200（isPrivateBase 深挖属 F08 范畴，前轮已 pass）✓
- F10：dashboard create/list/delete → 200 ✓

### I. UI 段（camoufox-cli 独立 session lane5ui，:3000）
- owner 登录 → 表右键菜单 "Edit table permissions" 可见（gate 解除生效）→ Permissions 面板三 key 摘要（Who can add records / Who can delete records / Table Visibility）
- Configure 弹窗：三组单选（含 Specific users）可见可选 ✓
- 保存链路：表弹窗切 Specific users 选人保存 → API 落库（API 侧等价路径已实测）✓
- Nuxt error overlay 双零（data-nuxt-error 无）✓；console error 无法经 camoufox-cli 直接读取（工具限制），以页面无 overlay + 功能正常作旁证

---

## E3 已知上游项（不计 error，有复现证据）

1. v1 bulkUpsert pure-update 批 500：零 grant 下 owner/editor 同样 500，`Cannot read properties of undefined (reading 'Id')`（上游 afterUpdate BaseModelSqlv2.ts:6065 一带）——豁免确认 ✓
2. v1 按 title 寻表 404（getByAliasOrId 上游行为）：`/api/v1/db/data/v1/:baseId/f03r4l5_tbl` 404（id 路径正常）——豁免 ✓

## 观察项（不构成 error）

- TABLE_VISIBILITY grant 的 enforce_for_form 属性无消费点（死配置，默认 true，无安全影响）；如 UI 允许对 VISIBILITY 配置该开关会造成误解，可在后续轮统一
- 测试脚本缺陷记录（非产品问题）：t1 base body 形状错误 + 协作者邀请缺失；t2 E 段与 D 段同 permission 唯一键冲突、bulk/update 路径笔误；t3 role:viewer 层级预期写反（role 型为 ≥ 语义）、form type 需数字枚举、副本 title 实际为 "<title> copy" 后缀（脚本找 "Copy of" 前缀）；t4 minimumRole 用「等于」测「低于」、两个误建 grant 占坑；t5 副本 title 匹配失败致段 3 断言打在源 base 上
- 流程教训：NocoDB 每次 signin 轮换 token_version 使同账号旧 JWT 全废——跨脚本共享 token 时 re-signin 会打断后续请求（本轮 3 次令牌失效均此因）；camoufox 共享 default session 多 lane 互踩会产出假观察（本 lane 的 owner 回显假阴性即此因，独立 session 复测推翻）

## 代码复审抽查（diff 7b10716231^..HEAD）

- 后端 hook 全在位：insert.ts single+bulk（bulk 单次 checkPermission 非逐行，skipPermissionCheck 豁免 import/copy）、nestedInsert（isPublicForm→isFormContext）、delByPk/bulkDelete/bulkDeleteAll、bulkUpsert 在 toInsert 拆分后判定
- extract-ids：主路径 ncTableId 设置（R2）+ v1 tableName fallback（getByAliasOrId）+ VISIBILITY gate（非 service user、空 grant fail-open、404 遮蔽）
- permissions.service：TABLE 三 key 白名单、Model 存在/归属/synced 拒绝、minimumRole、duplicate 拒绝——对称完整
- 错误文案 per-permission 且无内部泄漏；console.log/debugger 零残留；[CE-EE] 标记 21 处
- 前端：blockTableAndFieldPermissions gate 替换 isEeUI/showEEFeatures；!isEeUI 短路移除；TABLE_VISIBILITY 无 grant 默认 EVERYONE

## 质量门

- `npx tsc --noEmit`（packages/nocodb）→ exit 0 ✓
- `pnpm test`（jest Fork 桶）→ 2 suites passed, **26/26** ✓

## 清理

- 测试 base f03r4l5-base、f03r4l5-dup2 copy/src、其 snapshot/restored 产物、所有 grant、变量均已删（200）；f03r4l1/l2/l4 系（他 lane 资产）未动；浏览器 session 已关闭
