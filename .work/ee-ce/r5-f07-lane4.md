# r5-f07-lane4 (int + rev)

## 结论:PASS

## int(UI 浏览器实测,camoufox-cli @ localhost:3000,后端 :8080)

- 登录 f01e2e@ce-ee.local 成功(SIGN IN → dashboard)。
- API 建 base:`POST /api/v2/meta/bases` → `p628jh2dhgw7av0` "f07r5c_snap base"(xc-auth 头)。
- UI 纯点击导航(合成 MouseEvent,无整页 reload):base 卡片 → 左侧 rail Settings → Manage Snapshots。页面渲染真实组件(`.nc-base-snapshots`),含副标题、New Snapshot 按钮、空态文案、restore 提示行;非 `<NcSpanHidden />` stub。
- UI New Snapshot:点击 `[data-testid=base-snapshots-create]` → 后端 `GET /snapshots` 证实创建成功:`snapb3ybrwnbcm3dix`,副本 base `pp9vlho461f2ev9`,`status: completed`。
- UI 状态渲染:重进 snapshots 页,列表行显示 `Snapshot 2026-09-12T15-33-25 / 9/12/2026, 11:33:25 PM / COMPLETED / Restore`;restore 按钮仅 completed 可点(模板 `:disabled="snapshot.status !== 'completed'"` 一致)。
- Restore:点击 restore → **成功提示 toast** `"Snapshot restored as a new base"` 抓到(antd message)+ **跳转** `PATH=/nc/p19raait6wxixa7`;API 证实新 base `p19raait6wxixa7` = "f07r5c_snap base (restored)",UI 顶栏 "F07r5c_snap Base (Restored)"。二次 restore 复验:`/nc/ph76ie9lsn9yin2` 跳转 + toast 同样达成(两次稳定)。
- 断言结论:New Snapshot → COMPLETED → Restore → toast + 跳转,全链路 UI 实测通过。

### 环境备注(非 F07 缺陷,不计 error)

5 路 lane 并行共用同一账号,NocoDB signin 轮换 token_version 使旧 JWT 失效,会话被随机互踢(多次 401 → 前端跳 /signin)。所有断言均在重登后于有效会话内完成;受影响步骤均有 API 侧或二次实测佐证。并发互踢期间 UI 轮询(processing→completed 现场动画)被打断一次,以 API completed + UI COMPLETED 渲染佐证覆盖。

### 清理

restored×2、源 base、快照副本均删除(`DELETE /api/v2/meta/bases/*` 全 200);base 列表残留 f07r5c 项 = 0。

## rev(Snapshots.vue 终审 + vitest)

- `/Volumes/UNITEK/Documents/Development/nocodb/packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`(195 行)逐行审:
  - 错误处理统一走 `extractSdkResponseErrorMsg` + `message.error`,无静默吞错;`isLoading`/`isCreating` finally 复位无泄漏。
  - 轮询设计:按 id 单查(非全列表),24×2.5s 上限,completed/error break,列表 unshift/in-place 更新,key 用 `snapshot.id`。
  - restore:`navigateTo('/nc/${baseId}')` 镜像上游 getBaseUrl;`restoredBaseId` 缺失时降级为仅 toast;按钮 disabled 守卫 completed-only。
  - 删除:Modal.confirm 二次确认 + okType danger。
  - 无 v-html/eval;路径由 openedProject 派生;无注入面。
  - i18n 9 个 key + `labels.manageSnapshots` 全部存在于 `lang/en.json`(grep 实证);`SnapshotType` 在 `nocodb-sdk/src/lib/Api.ts:7940`。
- vitest 实跑:`npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **Test Files 2 passed, Tests 10 passed (10)**。

### 找茬

无(error 级)。

非 error 观察项(不计违反,供参考):

- Snapshots.vue:44 — 轮询循环内单次 GET 失败会中断整个轮询(有 error toast 反馈、重进页面自愈);建议后续可给单次轮询加 try/catch 继续。实测无法稳定触发,非缺陷。
- Snapshots.vue:166 — Restore 按钮无 loading 防连点;快速连点会产生多个 restored base。每次 restore 产生新 base 本就是产品语义,不算缺陷。
