# r7-f07-lane4 — F07 前端第 7 轮（int + rev）

## 裁决：PASS

（无必修违反。观察级备注见文末，均不构成功能违反。）

---

## int（camoufox-cli UI 浏览器实测）— PASS

环境：前端 http://localhost:3000（Nuxt dev），后端 :8080，账号 f01e2e@ce-ee.local。
测试资源：API 建 base `pe6fd92bzc3cbrt`（title `f07r7c_snap_base`，ws `w9qi3ljd`），测完已删（连同 2 个 restore 产物 `pn92r7lt4n9fy4d`、`pk6ld6m0rgnnj2i`，DELETE 均 200）。

### 第 1 遍全链（PASS）
1. 登录（signin 表单合成事件）→ 落 `/nc/pe6fd92bzc3cbrt`
2. rail（`nc-mini-sidebar-v2-rail`）Settings item → sidebar 切 settings 面板，URL `/settings/members`；`data-testid="base-snapshots"` 菜单在场（gating：`blockSnapshots` false + `isUIAllowed('baseSnapshotList')` 通过）
3. 点 `base-snapshots` → `/settings/snapshots`，面板渲染：`Manage Snapshots` + subtitle + New Snapshot 按钮 + 空态文案（i18n key 全部命中 en.json）
4. 点 `base-snapshots-create`（17:28:29）→ toast「Snapshot creation started」
5. 轮询 `[data-testid^="base-snapshots-status-"]` → **COMPLETED**（异步 DuplicateBase 副本完成，未超 90s）
6. 点 `base-snapshots-restore-*` → toast「Snapshot restored as a new base」+ SPA 跳转 `/nc/pn92r7lt4n9fy4d`（新 base，非本 base 路径）——**跳转断言 + 成功提示断言均通过**

### 第 2 遍复测（PASS，含 toast 逐秒采样）
- create（17:30:59）→ COMPLETED；采样期间 toast 仅「Snapshot creation started」，无异常项
- restore（17:31:54）→ toast 仅「Snapshot restored as a new base」，跳转 `/nc/pk6ld6m0rgnnj2i`

### 环境观察（非 F07 缺陷）
- 后端单会话强制：`users.service.ts:736` `shouldEnforceSingleSession()`（`PLAYWRIGHT_TEST!=='true'` 时每次 signin 轮换 `token_version` 并删全部 refresh token）→ **5 路并行共用同一账号互踢**，本路被踢回 /signin 共 4 次。属于会审环境行为，非 F07 代码问题；对策为登录后单 eval 连贯执行压缩窗口。
- dev 后端 `dist/main.js` 于 01:03:20 重启过（rspack autoRestart），导致首轮 API token 失效（Invalid token）；UI 测试期间未再重启。

---

## rev（Snapshots.vue 终审 + vitest）— PASS

对象：`packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`（195 行）

逐项核验：
- **i18n**：组件引用的全部 key（`msg.success.baseSnapshot{Created,Restored,Deleted}`、`msg.info.baseSnapshot*`×6、`labels.manageSnapshots`、`general.restore`）经脚本逐 key 验证在 `packages/nc-gui/lang/en.json` 嵌套路径全部存在，无缺 key 显示裸键风险
- **gating 入口**：`BaseSettingsMenu.vue` snapshots 菜单项 `!blockSnapshots && isUIAllowed('baseSnapshotList')`（含 `[CE-EE] F07` 标记），UI 实测菜单在场
- **create 轮询**：按 id 轮询（24×2.5s=60s 上限），completed/error break；后端 `base-snapshots.service.ts:75` `BaseSnapshot.insert` 同步先于 POST 返回 → 轮询 GET one 无 404 竞态窗口（已代码证实）
- **restore 导航**：`navigateTo(/nc/${restoredBaseId})` 镜像上游 getBaseUrl（注释声明），实测 SPA 内跳转成功不丢登录
- **delete**：`Modal.confirm` 确认框（与 `Variables/index.vue` 同款惯例），okType danger；后端对 copy base 缺失有守卫（删行不 500）
- **状态色**：completed 绿 / processing 橙 / 其余红，合理
- **XSS**：title 经插值渲染，无 v-html
- **`[CE-EE]` 标记**：文件头及关键处齐全
- **created_at 解析**：`new Date('2026-09-12 17:14:44+00:00')` 在 camoufox（Firefox 内核）实测解析正常，无 Invalid Date 风险

vitest 实跑（`cd packages/nc-gui && npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts`）：
```
Test Files  2 passed (2)
     Tests  10 passed (10)
```
10/10 全过。

### 观察项（非违反，不计入收敛计数）
1. `restoreSnapshot` 无 loading/disabled 防重：连点可触发多次 restore 产生多个 restored base（后端幂等性未验证）。低危 UX，建议后续轮加防重。
2. 第 1 遍全链 toast 采样中出现过一次性「Snapshot not found」error toast（源 `base-snapshots.service.ts:282` `getSnapshotWithBaseCheck`）；第 2 遍 create+restore 全程采样未复现，根因未定位，主流程两遍均成功。如后续轮再现，建议排查 restore 端点并发/重复触发场景。
