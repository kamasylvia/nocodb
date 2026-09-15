# F08 Private Base — R4 lane4 终局 UI 抽测报告

**结论：PASS**（0 error；1 观察项为上游遗留，非 F08 范围，不计入）

审查对象：6aea3db097（实现）/ 2a86eb7d6c（R1）/ b1d3ec3c5b（R2）/ c8e0c83e0f（R3）。
方法：API 铺数据 + camoufox-cli 浏览器 UI 抽测（owner/member 双账号、匿名 share 链接）+ c8e0c83e0f 代码辅审。

## 测试数据

- owner：`f08r4l4-owner@f08test.local`（nc_users_v2.roles=super，与各 lane 建库用户同模式）
- member：`f08r4l4-member@f08test.local`（org-level-viewer；workspace_user=workspace-level-editor；**无 nc_base_users_v2 行**）
- base：`p8auq6eudvway09`（f08r4l4-base，初始 is_private=f）+ table Table1；workspace `w9qi3ljd`
- share link uuid（public 态创建）：`7d7bac84-b2f4-4fdb-9fd7-c77aabd7e1b4`

## 步骤结果

### 1. Base Type 面板（owner）— PASS

- 路径：base 页 → 左 rail Settings → `/nc/p8auq6eudvway09/settings/members` → General tab → 子菜单 Base Type（`base-access-tab`）。
- 两卡渲染正常：`Workspace — Everyone in the workspace can access this base, based on their role.`（默认选中）/ `Private Base — Only you and members invited to this base can view and interact with it.`。截图 `03-basetype-workspace-selected.png`。
- 点 Private Base 卡：toast 文本 DOM 捕获 `Base type changed to private. Only invited collaborators can access it now.`；radio 选中态切至 Private（aria-checked true）+ 卡片高亮。截图 `04-basetype-private-toast.png`（toast 已消散，文本以 DOM 捕获为证）。
- 持久：整页 reload 后重开 General 面板，Private 仍选中（aria-checked true）；DB `nc_bases_v2.is_private=t`（psql nocodb-dev 实查）。截图 `05-basetype-private-persisted.png`。
- 回切验证：面板内 Workspace→Private 双向切换成功（第 5 步 collector 监测同轮完成），DB 终态 is_private=t。

### 2. Share Base 私有消隐 — PASS

- 语义核实（代码）：`packages/nc-gui/components/dlg/share-and-collaborate/ShareBase.vue:150` — Enable Public Access 的 `a-switch` 带 `v-if="!isPrivateBase"`；store `isPrivateBase` 接真实 `base.is_private`（store/base.ts:81，2a86eb7d6c 接线）。
- 实测（private 态 owner）：Share 按钮保留（协作者邀请入口）；弹层内 Enable Public Access **开关消隐**，代之以状态文案 `Sharing restricted` + 说明行 `This base is set as Private and cannot be shared publicly.`；`Manage Base Access` 按钮正常。截图 `11-share-dialog-private-no-toggle.png`。
- base 主页 topbar 显示 `Private` 徽章。截图 `10-owner-base-private-no-share.png`。
- 注：settings 页（members 路由）无 topbar Share 按钮，属页面上下文差异而非消隐（第一次误判已修正）。

### 3. member 可见性 / 直链零泄漏 — PASS

- API（xc-auth，member token）：`GET /api/v2/meta/bases` 列表不含 f08r4l4-base（private 前可见，切后隐藏，双向验证）；`GET /api/v2/meta/bases/:id` → **404** `Base not found`（存在性隐藏非 403）；`GET .../tables` → 404；`POST /api/v1/command_palette` 搜 "f08r4l4" → `[]`。
- 对照实验（防假阴性）：owner 同 palette 请求命中 base title + Table1 + view（`p-p8auq6eudvway09` / `tbl-mzzeb5da9s5kw1b` / `vw-...`）→ R3 palette 过滤真实生效。
- UI（member 登录）：工作区列表无 f08r4l4-base（body 文本检查）；直链 `/#/nc/p8auq6eudvway09` → 页面 title=default，无 base title/table 泄漏，落空骨架页。截图 `07-member-direct-link.png`。
- share 链接零泄漏：`GET /api/v2/public/shared-base/:uuid/meta` 在 privatize 后 → **400** `Shared base feature is not available for private bases. Please contact the base owner for access.`（public 态 200→privatize→400 实测，即 c8e0c83e0f 修复点）；匿名 session 打开 share URL → 重定向 signin（无 base 内容）；member 登录态打开 → 弹回工作区列表（无 base 内容）。截图 `08-share-link-private.png`、`09-share-link-anon.png`。

### 4. console error / 5xx — PASS（含 1 上游观察项）

- 前端：Base Type 面板双切换（两次 PATCH is_private + toast）在 window error + unhandledrejection collector 下 **0 error**（collector 装于面板文档内，SPA 导航会重置故仅覆盖单页操作面）。
- 后端 log（`.work/ee-ce/logs/backend.log`，762 行全扫）：本轮 UI/API 主流程 **0 个 5xx**；无 F08 相关 error。
- **观察项（非 F08 error）**：log:707/713/719 三次 `TypeError: Cannot read properties of null (reading 'super')` at `packages/nocodb/src/services/bases.service.ts:67`（`extractRolesObj(param.user?.roles)[SUPER_ADMIN]`，extractRolesObj(null)=null）。判定非 F08 引入：① 该行为上游 2023 代码（git blame e790abdbafa，merge-base 祖先），四个受审 commit diff 均未触及 baseList；② 复现排查：stale nc_token cookie → 干净 401、invalid token → 干净 401、legacy api token（无 fk_user_id，roles=undefined）→ 干净 403（R1 掩码生效），三类可疑路径均未复现 TypeError；③ F08 的 User.getWithRoles 改动只改 roles 赋值分支，不产生 null 返回。不阻塞、不计数；如后续轮想清零可在 baseList 加 `param.user?.id` 前置校验（上游同款问题）。

### 5. c8e0c83e0f 辅审（后端两改动 → UI 呈现路径）— PASS

- commandPaletteHelpers is_private 分支：member（无 base 行，workspace editor）palette 空、owner 命中——UI command palette 面板对私有 base 无 title/tables/views 泄漏，公共 base INHERIT 行为不变（owner 显式 owner 行命中）。
- publicMetas checkBaseType/checkViewBaseType：私有 base 的 pre-existing share link → public meta 400（上文实测）；share 前端页面对 400 的呈现 = 匿名跳 signin / 登录态弹回列表，无 base 内容渲染，无 console error。checkViewBaseType 为 8 个 view 级公共端点的 defense-in-depth，本轮未逐一打（R3 已验证 200→400→200 回环）。

## 证据清单

- 截图目录：`.work/ee-ce/shots-r4-l4/`（11 张，关键：03 两卡初始 / 04 Private 选中+toast 态 / 05 刷新持久 / 10 主页 Private 徽章 / 11 Share 弹层开关消隐）
- API 证据：上列各端点状态码均为实测 curl 输出；DB 实查 is_private=t（psql qnap.elf-balance.ts.net:5432/nocodb-dev）
- 代码锚点：ShareBase.vue:150（开关 v-if）、store/base.ts:81（isPrivateBase 接线）、components/dashboard/settings/base/index.vue（baseType tab + blockPrivateBases gate）、bases.service.ts:67（上游观察项）

## 残留说明（非 error）

- 测试 base `p8auq6eudvway09` 留于 nocodb-dev（private 态），与其他 lane 测试数据同惯例。
- owner 提权 roles=super 为建库必要（新用户 signup 落 Default Workspace 为 workspace-level-no-access，与既往各 lane 测试用户模式一致）。
