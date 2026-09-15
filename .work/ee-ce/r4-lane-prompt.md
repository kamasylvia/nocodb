你是 NocoDB CE-EE fork 的 F03 Data permissions 第 4 轮复审（R4）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

## 铁律
- **只读审查**：严禁修改/新建任何仓库源码文件（会触发 rspack 重建干扰他路）。只允许写报告文件和 /tmp 测试脚本。
- **隔离**：禁读 `.work/ee-ce/r*.md` 任何历史报告与他路报告。可读 TASK.md、AGENTS.md、GOAL-STATE.md、源码。
- **数据库红线**：只用 `nocodb-dev` 库（后端 dev server 已连好）。严禁碰 `nocodb` 生产库。
- 输出风格：压缩模式——去冠词/填充词/客套，保留全部技术实质。

## 环境事实
- HEAD = main 分支 ee85ce82c8（F03 实现 7b10716231 + R1/R2/R3 修复链 b28787a54a），工作树干净。先 `git log --oneline -12` 确认。
- 后端 dev：http://localhost:8080（rspack watch；若遇到中途重启等待恢复后重验该请求）。前端 dev：http://localhost:3000（Nuxt；**浏览器应用直连 :8080**——curl :3000/api/* 返回 text/html 是设计行为非故障）。
- 测试账号自建：参考 .work/ee-ce/r3-lane4/env.sh 的 signup/登录模式，账号名用你 lane 号前缀（f03r4lN-*）防串。
- 报告落盘：`.work/ee-ce/r4-f03-lane<N>.md`（<N> 见你收到的派遣附录）。测试完清理自己建的 base/grant/表。

## 审查对象（全量同规格）
1. **集成测试（全矩阵，API 实测 :8080）**：
   - TABLE_RECORD_ADD / TABLE_RECORD_DELETE / TABLE_VISIBILITY × granted_type nobody / role(editor|creator|viewer) / user × 角色 editor/creator/owner × v2 单条/bulk、v1 单插/单删/bulk/deleteAll/upsert。
   - fail-open（无 grant 全 200；删 grant 下一请求放行）；owner 直通；multi-grant any-deny；update 与 ADD/DELETE 正交；bulkUpsert 拆分语义（纯 update 批不要求 ADD、含插入行要 ADD）。
   - VISIBILITY：meta/data(v1+v2)/count/aggregate 404 遮蔽、表列表消失、role:viewer 档、user 精确匹配、Everyone=删 grant 往返。
   - 公开表单：enforce_for_form true→匿名 403 / false→200 往返。
   - 校验对称：create/update 非法 payload 全 400（nobody+subjects、role 缺 granted_role、user 缺 subjects、非法枚举、低于 minimumRole、重复键、跨 base 表）。
2. **R3 修复回归验证（b28787a54a 引入，重点逐项实测）**：
   - 弹窗 dirty-flag：a-select @change 置 dirty；SPECIFIC_USERS 改 users 后保存生效（不再静默丢）。
   - SPECIFIC_USERS 单选项默认态可见可选（原 v-if 死代码已去）。
   - save 前置校验：SPECIFIC_USERS 空选点 Save → 全 save 中止 + 报错 toast（不再删既有 grant 也不假成功）。
   - owner-role grant：API 造 role:owner → UI 弹窗回显 Creators & up → 保存 → API 侧 granted_role 仍 owner（不降权 creator）。
   - NOBODY 转换：PATCH role→nobody 后 DB granted_role 为 null（查库或 GET 验证）；随后 PATCH {granted_type:role} 不带 granted_role → 400（复活守卫）。
   - user→role 切换后 subjects 行清空。
   - bulk 插入性能：100 行 bulk（role:creator + ADD grant）耗时应与无 grant 同量级（R3 前放大 ~2x，已修）。
   - **duplicate/restore 带 grants**：原 base 表级 grant（如 VISIBILITY nobody）+ 字段级 grant（F02）→ POST /api/v2/meta/duplicate/:baseId → 副本 base 的 /permissions 应带出对应 grant 且 entity_id 映射到新表/新列 id；字段 grant subjects 保留。importPermissions 逐 grant 容错（构造非法 grant 的 export 难以直接做，可代码审替代）。
3. **代码复审（整个 diff，git diff 7b10716231^..HEAD 或逐 commit）**：R1-R5 修复在位性、checkPermission any-deny、extract-ids ncTableId 主路径+v1 fallback、importPermissions 新实现正确性（id 映射、subjects 过滤、容错）、console.log/debugger 残留、错误文案无内部泄漏、[CE-EE] 标记完整。
4. **回归**：F02 字段权限（RECORD_FIELD_EDIT 403/owner 通/删 grant 200）、F05 变量、F07 快照 create+列表+restore、F08 私有 base、F10 dashboard 全 API smoke。
5. **UI 段（camoufox-cli，:3000）**：owner 登录 → 表右键/Details → Permissions tab 三 key 摘要与 API 一致 → Configure 弹窗（三组单选含 Specific users 可见可选）→ 切 user 型选人保存 → API 侧 grant 落库正确。console error / Nuxt error overlay 双零。camoufox 多路并跑易互踩：用独立 session，异常时重开。
6. **质量门**：`cd packages/nocodb && npx tsc --noEmit`（期望 exit 0）+ `pnpm test`（jest Fork 桶 26/26）。前端不强制全量 vitest（已知 worker 超时噪音），如跑只跑定向文件。

## 已知上游 E3（勿重复计入 error，可引用证据）
- v1 bulkUpsert 纯 update 批 500（afterUpdate BaseModelSqlv2.ts:6065，上游 2023 代码，owner 零 grant 同炸）
- v1 按表 title 寻表 404（getByAliasOrId 上游行为）
- 公开分享面（sharedViewMeta）不消费 TABLE_VISIBILITY（上游 CE 预埋面缺失，backlog ⑧）
- duplicate 副本 permissions 的 UI 刷新时机等前端观察项已记录

## 报告格式（写入指定报告路径，正文中文）
- 首行结论：`PASS（0 error）` 或 `issues（N 项）`
- issues 列表：`文件:位置:问题:建议`
- 实测证据：关键断言的 method/path/状态码/耗时
- E3 项单独列（有诊断证据）

最终回复：给结论 + issues 摘要 + 报告路径。
