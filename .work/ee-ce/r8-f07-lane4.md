# r8-f07-lane4 — 第 4 路(int + rev)

## rev(代码复审 + 测试)

**测试**:`cd packages/nc-gui && npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → **10/10 通过**(base-variables-acl 2 + unique-constraint-helpers 8,exit 0)。

**终审对象**:`packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`(194 行)

逐项核验:
- i18n key 全存在(en.json + zh-Hans.json 各 10/10):baseSnapshotCreated / baseSnapshotRestored / baseSnapshotDeleted / baseSnapshotDeleteTitle / baseSnapshotDeleteDescription / baseSnapshotsSubtitle / baseSnapshotCreate / baseSnapshotsEmpty / baseSnapshotsRestoreHint / labels.manageSnapshots;`general.restore` 亦在
- API 路径与后端一致(list/get/create/restore/delete,均 `/api/v2/meta/bases/:id/snapshots*`)
- 异步创建轮询:按 id 轮询(非全列表),24×2.5s=60s 上限,completed/error 即断;轮询窗口用尽时 UI 停留 processing 但 restore 按钮 `:disabled="status!=='completed'"` 守住,重进页面即见终态 — 无错误行为,不构成 issue
- restore 成功分支 `navigateTo('/nc/' + restoredBaseId)` 镜像上游 getBaseUrl(实测跳转正确)
- delete 走 Modal.confirm → API → 重载列表;所有 catch 走 `extractSdkResponseErrorMsg`,无裸 console
- 无 v-html / XSS 面;`data-testid` 覆盖 create/row/status/restore/delete
- created_at 解析(非标 `2026-09-12 19:58:10+00:00`)在 Firefox 内核(camoufox)实测渲染正常

找茬:**无**。

## int(UI 浏览器实测,camoufox-cli → http://localhost:3000)

前置:API 建 base `f07r8c_base4`(id `p8rc2mjonh86imb`,已测完删除)。

| 步骤 | 结果 |
|---|---|
| UI 登录 f01e2e@ce-ee.local → dashboard | OK |
| 点击打开 f07r8c_base4 | OK(`href=/nc/p8rc2mjonh86imb`) |
| mini-sidebar Settings → 设置面板 | OK(`href=.../settings/members`,菜单含 Variables / Manage Snapshots,无 upgrade 弹窗) |
| Manage Snapshots → 快照面板 | OK(`href=.../settings/snapshots`,`.nc-base-snapshots` 渲染:标题/副标题/New Snapshot/空态/restore 提示,非空壳) |
| UI 点 New Snapshot | OK,~10s 内行内状态 **COMPLETED**,Restore 按钮解禁;后端确认副本 base `pxcztvr2lf1cvsn`(Snapshot 2026-09-12T19-58-10 of f07r8c_base4) |
| UI 点 Restore | OK,**跳转 `href=/nc/p5z7m3dy4gmcctd`**,新 base title=`f07r8c_base4 (restored)`,页面正常渲染 |
| 清理 | 3 个 base(restored / snapshot / source)DELETE 全 200 |

### 环境观察项(非 F07 范围,不构成 issue,供 orchestrator 参考)

int 过程多次被随机登出,实证归因为两层环境叠加,均非 F07 diff 引入:

1. **共享测试账号竞争**:5 路并发共用 f01e2e,任一路 signin 旋转 `token_version` → 他路存量 JWT 全部 401(后端 `src/strategies/jwt.strategy.ts:34-40`,日志实证 `Token Expired`)。期间 base 列表可见 f07r8a/f07r8b/f07l5r8 等他路资源并发增长,竞争实锤。
2. **dev 跨 origin refresh 必败**:nc-gui dev 直连 `http://localhost:8080`(`lib/constants.ts:46` BASE_FALLBACK_URL),后端 CORS 返回 `Access-Control-Allow-Origin: *` 且无 `Access-Control-Allow-Credentials`;前端 401 拦截链(`composables/useApi/interceptors.ts`)→ `refreshToken` 以 `withCredentials:true` 请求 `/auth/token/refresh` → 浏览器直接 NetworkError(credentials 请求禁配 `*`)→ 必然 signOut。后端带 cookie 直调该端点 200 正常,纯 CORS 层问题;生产同源('/')不受影响。

缓解(本轮实测有效):API signin 后将 token 写入 `localStorage['nocodb-gui-v2'].token` 再导航(避免二次 signin 踩 version);窗口期内 UI 全流程可完成。

## 总裁决

**PASS**(rev 无 issue;int 全链路断言通过;环境观察项不属 F07)
