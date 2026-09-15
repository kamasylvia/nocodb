# r3-f07-rev-b — 第 4 路（int UI 实测 + rev 代码终审）

## rev：packages/nc-gui/components/dashboard/settings/base/Snapshots.vue 终审

- 轮询（R2 修复确认）：createSnapshot 按 id 定点轮询 `GET /api/v2/meta/bases/:id/snapshots/:newId`，24×2.5s=60s 上限，completed/error 即 break（Snapshots.vue:41-53）✓
- 跳转：restore 后 `navigateTo(/nc/${restoredBaseId})`，镜像 upstream getBaseUrl（Snapshots.vue:69-72）✓
- 门收敛：组件内无 gate；入口门 `!blockSnapshots && isUIAllowed('baseSnapshotList')`（components/project/View.vue:642,195）；`blockSnapshots = computed(() => false)`（composables/useEeConfig.ts:427）；ACL 前端 lib/acl.ts:143 / 后端 src/utils/acl.ts:274 两侧一致 ✓
- i18n：en.json 全部 11 key 在位（manageSnapshots:2739、baseSnapshots*:5797-5802、baseSnapshotCreated/Restored/Deleted:6163-6165、general.restore/delete/cancel）✓
- [CE-EE] 标记：Snapshots.vue:2,33,70 ✓；类型 SnapshotType（nocodb-sdk Api.ts:7940）✓
- vitest：`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → 2 files / 10 tests passed ✓
- 后端路由四件套（list/create/get-one/restore/delete）base-snapshots.controller.ts 全在位，@Acl('baseSnapshotList') 等 ✓

轻微观察项（非 error，不计违反）：
1. 轮询无 onUnmounted 守卫——创建期间离开页面会继续轮询至 60s 上限。无害。
2. `new Date(snapshot.created_at)` created_at 类型可缺省，缺省时渲染 "Invalid Date"；后端恒返回。无害。

## int：camoufox UI 浏览器实测（http://localhost:3000，隔离用户 f07r4ui@ce-ee.local）

环境插曲（非 F07 问题，有诊断）：会话前段后端被他路文件编辑触发 rspack 连环重建（90s 内 main.js 两次重建）+ 多路代理共用 f01e2e 触发 token_version 轮换互踢，UI 会话反复失效。处置：dev-backend.sh stop → 带 `NC_AUTH_JWT_SECRET` 钉死重启（watch 重建继承 env，secret 稳定）+ 建隔离测试用户入 workspace。恢复后全流程无中断。

实测链路（纯点击导航，无 open reload）：
1. UI 登录 → workspace base 列表 → 搜索点击打开 f07r4ui_snap-ui-test（p8ysdtikqpv9nd1，API 预建）✓
2. Settings（/settings/members）→ Manage Snapshots 菜单可见 → 点击进入 /settings/snapshots，真实 UI 渲染（标题/副标题/空态文案，非 NcSpanHidden 空壳）✓
3. 点 New Snapshot（data-testid=base-snapshots-create）→ toast "Snapshot creation started" + 行 `base-snapshots-row-snap43ezvn660cmiqr` 出现 → 状态 COMPLETED（空 base 秒完）✓
4. 点 Restore → toast "Snapshot restored as a new base" + 跳转 /nc/pwydwydeexqxsp2，新 base 页面渲染标题 "F07r4ui_snap-Ui-Test (Restored)" ✓
5. 插桩 XHR/fetch 记录器全程 0 个 ≥400 请求，无 console 网络错误 ✓

清理：snapshot delete（200，级联删副本 base p92vn14conjjjzv）、restored base pwydwydeexqxsp2（200）、原 base p8ysdtikqpv9nd1（200）。残留 f07r4ui_snapiso/snapbase 系另一路同前缀在测资源（创建于 4 分钟前），未触碰。遗留隔离用户 f07r4ui@ce-ee.local（workspace-level-creator，nocodb-dev）。

## 裁决

PASS

（rev：PASS；int：PASS；总计 0 error。观察项 2 条均已判定非 error 级。）
