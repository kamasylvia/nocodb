# F09 R5 — lane3 复审报告（Table Sync P1，R4 修复批 798e860dd1 回归）

- 审查员：R5 独立第 3 路（ZCode subagent，隔离，未读他路报告）
- 日期：2026-09-18
- 后端：:8080 全程 200（未触碰进程）；前端 :3000 发现宕机后**自起** :3003 Nuxt dev（自己的进程，审查毕已停，:3000 属他人实例未动）
- 测试数据：账号/base 全 `f09r5l3-*` 前缀，审查毕已全部删除（bases 列表残存 = 0）

## 结论

**2 error（均 API 活体复现，证据链完整）→ 本轮不清洁；连击重开。** R4 修复批本身的两个目标项（ws-level-no-access 拒绝、debug 残留清除）回归 PASS，但按 R4 同款方法论扩展矩阵时，发现 `assertSourceReadAccess` 与平台层 base 可见性语义仍存在**双向分叉**（一漏堵 = 数据泄露复发；一过堵 = 标准协作流向导死路）。

---

## E 级发现（必修候选）

### E1 [error] 私有 base 分支漏判 `inherit` 角色行 —— 私有库数据可被完整镜像外泄（R2 E1 同类复发）

- 复现路径（全部活体实测，:8080）：
  1. 用户 U 自注册（默认 `workspace-level-no-access`）；
  2. base owner 邀请 U 到**私有**源 base，角色 `inherit`（`base-users.service.ts:90` 允许该角色，邀请 200）；
  3. 平台层：U `GET base` = **404**、`GET records` = **404**（base 对 U 完全隐藏，符合 F08 语义，实测确认）；
  4. U 对 dest base 有 creator 角色，调 `POST .../table-syncs/source-schema` = **200**（`table-syncs.service.ts:117-119` 只排除 `no_access`/`no-access`，`inherit` 漏网）；
  5. U 调 `createSync` = **200**，引擎 full-create 完成，镜像表出现源全部 3 行（prow1-3），U 读取镜像 = **200**。
- 根因：`BaseUser.ts:563-631` 的平台可见性 SQL 明确 `roles NOT IN ('no-access','inherit')` 才算显式协作；assertSourceReadAccess 私有分支只排除了 no-access 系。
- 定性：R2 E1（无关系用户读私有源 base）修复不完整的姊妹洞——同样的"平台隐藏、sync 放行"泄露形态，只是入口从零关系行换成 inherit 行。

### E2 [error] 非私有 base 分支完全无视 base 级显式角色 —— 标准协作流向导死路（R3/R4 修复方向收窄过度）

- 复现路径（活体实测）：
  1. 用户 V 自注册（默认 `workspace-level-no-access`）；
  2. owner 邀请 V 到**非私有**源 base，角色 `editor`（标准 base 协作流，邀请不提升 ws 角色——`base-users.service.ts` 现有用户路径只写 `nc_base_users_v2`，且新建用户路径显式保持 ws `NO_ACCESS`，代码注释原话 "role management happens at workspace or base level"）；
  3. V 同时为 dest base creator；
  4. 平台层：V `GET base` = **200**（显式 base 角色，第一优先级放行，实测确认）；
  5. V 调 `source-schema` = **404 "Base not found"**、`createSync` = **404**（`table-syncs.service.ts:124-137` 非私有分支只看 `workspace_roles`）。
- 定性：R3 修复的初衷是消除"无 base 关系用户 404 死路"；R4 增加排除了 ws-level-no-access。但现在的非私有分支**只实现了 workspace 继承半边**，把「显式 base 角色协作者」这个平台第一优先级全部误拒。凡是走 base 邀请的协作者（自注册默认 ws-no-access，即绝大多数 CE 协作用户）都无法创建 sync——P1 主流程对该人群整体不可用。
- 与 E1 同根：断言未复刻平台谓词。平台语义（`BaseUser.ts:563-631`）：
  `allow = 显式base角色 ∉ {no-access, inherit} OR (base角色 ∅/inherit AND ws角色 ∉ {workspace-level-no-access})`，私有 base 只走第一析取支。
- 修法建议（供裁决）：assertSourceReadAccess 按上述谓词重写（私有 = 仅第一支；非私有 = 两支 OR），或抽与 BaseUser listing 同源的公共判定，避免第三轮再修出新一侧偏差。

---

## m 级 / 观察项（不计 error）

- **m1**：R4 修复批在 `table-syncs.service.ts:471/473/487` 留下缩进异常（8 空格 `if (grid?.id)`、`}` 缩进错位）——纯格式，语义不受影响，建议 prettier 顺过。
- **m2**（测试基建）：向导 base 下拉（NcSelect filterable 虚拟列表）在 camoufox CLI 下无法脚本化选中（选项渲染但 filter 输入与 ref 点击不生效）——非产品缺陷（上游通用组件），step1/2 按钮渲染以静态代码 + 实现方/R1-R4 截图佐证。
- **m3**（测试基建）：v2 无 `PATCH/DELETE /records/:id` 单行路由（404），单行变更须走 body-Id 形式——本轮三个引擎假 FAIL 由此产生，复测后全绿，供后续 e2e 脚本对齐。
- **m4**（环境教训再现）：同账号 API signin 踢掉 UI token_version（GOAL-STATE 已录）——本轮 UI 掉线一次复现；校验类 API 调用应固定用独立账号。

## R4 修复批回归项（PASS）

1. `is_private` 分流：out（ws-no-access，零关系）对私有 = **404** ✓（R2 E1）、对非私有 = **404** ✓（R4 修复目标）；cr（dest-creator、无源关系）= 404 ✓；owner 双向 200 ✓。
2. console.debug ×4 全部清除（`F09-hide` 全仓 grep 零命中）✓。
3. jobs-map `[CE-EE] F09` ×3 在位 ✓。

## 8 项清单核验

1. **diff 审查** ✓：全链 71896a841f→798e860dd1 共 16 文件与实现报告一致；后端 [CE-EE] 标记齐全（service 12 / controller 2 / processor 4 / model 1 / jobs-map 3 / 前端均有）；`store/sync.ts`、`syncUtils.ts`、`ncUtils.ts`、`acl.ts` 零改动；`isSyncFeatureEnabled` 恒 false。
2. **引擎审查** ✓：RemoteId 键控 upsert 正确（full-create 3 行 RemoteId=1/2/3；resync +1 插 / 1 改 / 1 删全部对账）；源/dest 双侧 500/页分页；白名单通道仅引擎内部（`allowSystemColumn`+`skip*`，editor 直写 400 佐证不可达）；失败路径实测：删源表 → resync → `status=error` + `last_error="Source table has been deleted — delete this sync and recreate it"`。
3. **服务审查** ✓（除 E1/E2）：allow_sync 强制（无 qualifying 视图 400）；镜像列过滤（LTAR/附件/系统列排除；selectedFields=["Title"] 实测镜像表只有 Title 无 Qty）；保留名守卫在位；realtime 触发 400；system:true 后置补丁 + list 缓存失效（镜像表 RemoteId/RemoteDeleted `system=true` 实测）。
4. **ACL 矩阵** ✓（除 E1/E2）：owner 十端点 200（resolve-link 501 如约）；editor/viewer 十端点 ×2 全 403；匿名 401 ×2。
5. **引擎 e2e** ✓：full-create→RemoteId 对照→resync upsert→on_delete 双策略（delete：row3 消失；mark_deleted：prow2 保留 + RemoteDeleted=true，其余 false）→freeze（resync 400）→resume→deleteSync（GET 404 + 镜像表离开 tables 列表）。
6. **守卫链 + 系统列** ✓：owner/editor 对 synced 表 insert 400；删镜像表 400；form 视图 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`；镜像 readonly 列改名 400（对照组：editor 对普通表建 form 200——守卫不误伤）；RemoteId/RemoteDeleted `system=true`+`readonly=true`+grid `show=false` 三重全中，其余列全部可见。
7. **UI 段** ✓（camoufox `--session f09r5l3` 专属）：向导打开、step0 `Next` **在 body 渲染**（R2 E1 修复活体确认）且未选中时禁用（back/create 按步条件正确）；树节点菜单 Sync now / Pause sync / Delete sync 全渲染；**Pause sync 点击 → API status=paused；Resume sync 点击 → active**（独立账号 API 核验）；StatusBadge 渲染 `Paused` 状态行；**editor 视角：Overview NocoDB Sync 卡 / 树 F09 菜单项 / Share 面板三者全不可见**；console error `[]` + vite/nuxt overlay 无。
8. **回归 + 质量门** ✓：F07 snapshots / F05 variables / F10 dashboards / F03 permissions / F04 syncs 探针 200，F02/F08/AirtableImport 探针无 5xx；`tsc --noEmit` exit 0；jest Fork 桶 **41/41**。

## 已知限制沿袭（未升级，不计 error）

resync 全字段盲刷；附件列不镜像；保留名 400；selected_fields 变更拒收（P2）；realtime 400（付费锁）；resolve-link 501；FAILED 详情泛型；并发 syncing 互斥设计。

## 纪律留痕

- 只读审查：零源码改动；脚本与截图全在 /tmp。
- 数据：`f09r5l3-*` 前缀账号 7 + base 6（含一次 bootstrap 重跑产生的 3 个孤儿 base，均已删），dev 库残存 0。
- 未跑任何 dev-backend*.sh / pkill；未重启后端；camoufox 会话 `f09r5l3` 已 close --all；自起的 :3003 Nuxt dev（pid 44376）已停止。
