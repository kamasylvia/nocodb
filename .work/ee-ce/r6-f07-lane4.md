# r6-f07-lane4 — F07 前端第 6 轮收敛确认(int + rev)

## int(UI 浏览器实测)— PASS

camoufox-cli 独立 session 驱动 http://localhost:3000,全流程实测通过:

1. **API 建 base**:`POST /api/v2/meta/bases` → `f07r6c_snap_base`(id `pieqga14oeng8kl`,自动带 pg source)。
2. **UI 登录**:表单登录成功,SPA 跳转 workspace 页。
3. **UI 打开 base**:合成 MouseEvent 点击 base 卡片(`nc-base-list-modal-base-title-*` 根节点)→ 跳转 `/nc/pieqga14oeng8kl`。
4. **Settings → Manage Snapshots**:snapshots tab 面板完整渲染 —— 标题 Manage Snapshots、副标题、New Snapshot 按钮、空态文案齐全;**无 upgrade 弹窗、无 `<NcSpanHidden />` 空壳**。gate(`blockSnapshots`)+ ACL(`baseSnapshotList`,base creator)实测放行。
5. **UI New Snapshot**:点击后 toast「Snapshot creation started」;列表行实时出现(组件内按 id 轮询逻辑生效);约 2s 后状态 **COMPLETED**(snapbbiviep1y92vvp,copy base `po2xd3eqf4ufjs2`,API 侧确认 status=completed)。
6. **Restore**:点击 restore 按钮 → **跳转 `/nc/p1uzen22cvxk7su`**;API 确认新 base title=`f07r6c_snap_base (restored)`;UI sidebar 已显示跳转后 base。断言达成。
7. **清理**:DELETE snapshot(200,登记行+copy base 同清)、DELETE restored base(200)、DELETE 源 base(200);base 列表无 `f07r6c` 残留。

### 环境备注(非被测代码问题,不计违反)

- 5 路并发共享同一 dev 后端 + 同一测试账号:`users.service.ts` setRefreshToken 的单会话强制(每次登录 rotate token_version)+ rspack 文件变动重启(重启后 JWT 失效)导致测试期间多次被动登出。已改用独立账号 `f07r6c@lane4.local`(经 base invite 为 creator)规避互踢;跨重启重登续测。所有断言在有效会话内实测达成,无一带豁免。
- 手法备注:合成事件对普通 Vue 组件有效;antd tabs 合成事件不响应,SPA 内改以 `history.pushState + popstate` 触发 `?page=snapshots`(View.vue `route.query.page` watch → `projectPageTab='snapshots'`,真实代码路径)。
- 同名文件冲突说明:报告落盘时发现既存同名文件(疑同 lane 重派残留),已保留改名为 `r6-f07-lane4-prev-20260913.md`,本文件为本轮实测产出。

## rev(代码复审)— 无 error 级问题

- **vitest 实跑**:`test/base-variables-acl.test.ts` (2) + `test/unique-constraint-helpers.test.ts` (8) = **10/10 passed**(314ms)。
- `Snapshots.vue` 终审:
  - i18n key 全部存在(`lang/en.json`:baseSnapshotCreated/Restored/Deleted/Create/Empty/Subtitle/RestoreHint/DeleteTitle/DeleteDescription/manageSnapshots/restore)。
  - 后端契约对齐:list 返回数组 / status 小写枚举(processing|completed|error)与 `statusColor` 匹配 / restore 返回 `{base_id}` / `navigateTo('/nc/{id}')` 与上游 getBaseUrl 一致。
  - 创建轮询上限 24×2.5s=60s,超时静默停轮询(行留 processing;后端 `deriveStatus` 下次 GET 自愈,service 另有 15min 兜底)——边缘可接受。
  - 后端抽查(`base-snapshots.controller.ts` / `base-snapshots.service.ts`):5 路由 + ACL 齐全;R1/R3/R4/R5/R7 修复在位(copy-base 无缓存探查、RootScopes.WORKSPACE、title 150 截断);create mutex 残差风险已注释文档化。

### minor 观察(单路,不构成 error,不要求本轮修复)

- `packages/nc-gui/components/dashboard/settings/base/Snapshots.vue:166-172` — restore 按钮无 loading/防重复点击,快速双击理论上会并发两个 restore POST 产出两个 restored base(后端无幂等守卫)。本轮未实测复现(单击路径正常);建议后续给 restore 按钮加 pending 态禁用。

## 总裁决

**PASS**(int PASS + rev 无 error;1 条 minor 观察仅供 orchestrator 参考)。
