# F08 R3 lane4 — 浏览器 UI 实测 + 代码辅审（收敛第 2 轮）

## 结论

**PASS**（0 error）

观察项（非 error，不计违规）：
- `packages/nc-gui/components/dashboard/settings/base/Access.vue:101` — loading spinner 显示条件 `isUpdating && opt.value === isPrivate` 在 PATCH 进行期间转圈图标落在**旧选中卡**上（目标卡无反馈）。行为正确、无功能影响，属展示位置语义，不构成 error。
- 无角色成员直访私有 base URL：无重定向、无 toast，页面降级为 workspace 空态（Getting Started 骨架）。**零泄漏已验证**（base 名/表名/base id 均不在 DOM，meta API 404 `ERR_BASE_NOT_FOUND`），安全语义达标；提示形式与预期「重定向/toast」不同，记录备查。

## 审查对象

- 6aea3db097（实现）+ 2a86eb7d6c（R1 修复）+ b1d3ec3c5b（R2 小项）
- 环境：前端 :3000 / 后端 :8080（dist/main.js pid 18649）/ nocodb-dev

## 步骤结果

### 1. API 铺数据 — OK
- signup 3 用户：`f08r3l4-owner@lane4.test`（DB 提权 roles='super'）/ `f08r3l4-collab` / `f08r3l4-norole`
- base `p28e7qubxphe4d8`（ws `w9qi3ljd`）+ table `tbl_main`（id `m4ynmndlf27whe2`）
- collab 邀为 base editor（`POST /api/v2/meta/bases/{id}/users`）；norole 邀为 workspace-level-editor（`POST /api/v1/workspaces/{id}/invitations`，body 为 `{email, roles:"workspace-level-editor"}`，无 base_users 行）
- 公开基线：collab 列表见 ✓、norole 列表见 ✓

### 2. Base Type 面板（owner，camoufox-cli）— OK
- base 下拉菜单 → Settings → URL `/nc/{base}/settings/settings?tab=baseType`（默认 tab = baseType，符合 `settings/base/index.vue` getDefaultTab）
- 两卡渲染：`radio "Workspace …" [checked]` + `radio "Private Base …"`；无 upgrade 弹窗、无 `<NcSpanHidden />` 空壳
- 切 Private：toast「Base type changed to private. Only invited collaborators can access it now.」+ Private `[checked]`；**reload 后仍 [checked]**（持久 OK）；后端 `is_private:true` 回读确认（UI PATCH 落库）
- 切回 Workspace：toast「Base type changed to workspace. …」+ Workspace `[checked]` 恢复
- 截图：`ui-f08-r3-l4-01-base-type-panel.png`（初始态）、`ui-f08-r3-l4-02-private-selected.png`（私有选中）、`ui-f08-r3-l4-04-switch-back-workspace.png`

### 3. Share Base 开关 — OK
- 私有态（table view）：Share dialog 两节均受限 —
  - Share View：「Views within a Private base cannot be shared publicly.」/ Enable Public Viewing → **Sharing restricted**
  - Share Base：「This base is set as Private and cannot be shared publicly.」/ Enable Public Access → **Sharing restricted**
  - 另有「Manage Base Access」CTA。截图 `ui-f08-r3-l4-03-share-dialog-private.png`
- 公开态：restricted 文案消失，开关恢复（API 侧亦验证：私有建 share 400「Shared links are not available for private bases…」，公开 200）

### 4. 可见性（UI 实测，私有态）— OK
- collab（显式 editor）：workspace 列表见 `f08r3l4-priv-base` ✓；直开 table URL 正常渲染 ✓（截图 `ui-f08-r3-l4-05-collab-sees-private.png`）；settings 无 Base Type tab（`base-access-tab` 不存在、0 radio，editor 无 `manageBaseType` ACL 屏蔽生效）✓
- norole（workspace 成员无 base 行）：列表 **count=0** ✓；直链 DOM 泄漏扫描 `f08r3l4-priv-base`/`tbl_main`/`p28e7qubxphe4d8` 全零 ✓（截图 `ui-f08-r3-l4-06-norole-direct-link.png`）
- norole 页内以其真实 JWT fetch `/api/v2/meta/bases/{id}` → **404 `ERR_BASE_NOT_FOUND`**（隐存非 403）✓

### 5. i18n zh — OK
- localStorage `lang=zh-Hans` 后重登：面板全中文「项目类型 / 工作区 / 私有项目」+ 两段描述，`rawKeyLeak:false`（无 `labels.`/`title.`/`msg.info` 裸 key）。截图 `ui-f08-r3-l4-07-zh-panel.png`
- zh toast：「Base 类型已改为工作区共享…」捕获成功（ZH-TOAST-OK）
- zh Share dialog（公开态）：「分享视图/启用公开查看/分享项目/启用公共访问/关闭/管理项目访问」无裸 key。截图 `ui-f08-r3-l4-08-zh-share-dialog-public.png`
- 代码侧：Access.vue 引用的 8 个 key（`general.baseType`、`labels.workspace`、`title.privateBase`、`title.baseTypeTabSubtext`、`title.baseTypeSettingsDefaultSubtext`、`title.baseTypeSettingsPrivateSubtext`、`msg.info.baseTypeChangedToPrivate/ToWorkspace`）node 解析 en.json/zh-Hans.json 双语全部命中

### 6. console error / 5xx — 双零
- 页面探针（console.error + window error + unhandledrejection + fetch/XHR ≥500 hook）覆盖流：grid 加载、Share dialog 开/关、SPA 设置导航、Private↔Workspace 两次 toggle（2 个 PATCH）→ **cerr=[] perr=[] http5xx=[]**
- 服务端：`.work/ee-ce/logs/backend.log` 9571 行 grep `Internal Server Error/unhandled/TypeError` — 命中的 `body.title.trim is not a function` 8 条均来自 **旧实例 pid 97876**（时间戳非本轮窗口），非 F08 端点（F08 PATCH 仅 is_private）；`grep f08r3l4` 0 命中

### 7. 代码辅审 — OK
- `packages/nc-gui/lib/acl.ts:153`（b1d3ec3c5b 措辞修正）：注释「creator+ only; OWNER reaches it through role-scope include merging」与实现一致 — `manageBaseType:true` 挂 base-scope CREATOR 段（:155），OWNER 经 :320-331 同 scope include 级联合并继承
- `Access.vue` 终审（竞态/严格比较）：`val === isPrivate.value` 布尔严格比较 ✓；`isUpdating` 防并发重入 ✓；catch 不改本地态（失败无伪成功）✓；`(base.value as any).is_private = val` 直接写 store reactive 对象 ✓
- `settings/base/index.vue`：gate 改 `!blockPrivateBases.value && isUIAllowed('manageBaseType')`，与 `useEeConfig.ts` `blockPrivateBases = computed(() => false)` 一致；无 tab 者走 getDefaultTab fallback，selectMenu 二次拦截

## E3 环境限制（有诊断证据，非 error）

- 共享 dev 后端多 lane 并行期间出现间歇 401（新签 JWT 数分钟后失效，重签即恢复）。证据：`ps` 见 rspack watcher（pid 86799，6:00AM 起）+ server（pid 18649，1:06AM 起）双进程；首轮 health uptime 567s（≈01:02 起）与后测 1775s（≈01:16 起）矛盾，怀疑测试窗口内 main.js 被 watcher 重建重启过；backend.log 无任何 `f08r3l4` 401 记录（401 不入 GlobalExceptionFilter）。均为 dev infra 噪音，401 路径属上游 auth 代码，不在 F08 diff 范围。
- 一次会话掉线由本轮测试自身 eval 改写 `nocodb-gui-v2` localStorage 与应用 hydrate 竞态所致（非产品缺陷），重登后 reload 持久性正常。

## 截图清单（均在 .work/ee-ce/）

1. ui-f08-r3-l4-01-base-type-panel.png — 面板初始态（Workspace checked）
2. ui-f08-r3-l4-02-private-selected.png — Private 选中态
3. ui-f08-r3-l4-03-share-dialog-private.png — 私有态 Share dialog（两级 Sharing restricted）
4. ui-f08-r3-l4-04-switch-back-workspace.png — 切回 Workspace
5. ui-f08-r3-l4-05-collab-sees-private.png — collab 打开私有 base
6. ui-f08-r3-l4-06-norole-direct-link.png — norole 直链空态（零泄漏）
7. ui-f08-r3-l4-07-zh-panel.png — zh 面板
8. ui-f08-r3-l4-08-zh-share-dialog-public.png — zh Share dialog 公开态
