# UI 冒烟结果 — F01/F05/F07（camoufox-cli 本地真实浏览器, 2026-09-12）

环境：nuxt dev :3000（NUXT_PUBLIC_NC_BACKEND_URL=隧道 API；本地直连 :8080 亦可）+ 后端 :8080（nocodb-dev）。登录 f01e2e@ce-ee.local。

## F05 Variables — 全过

- 深链 `/w9qi3ljd/{baseId}/settings/variables` 直达 tab（continueAfterSignIn 登录流正常）
- 菜单/侧栏同时可见「Variables」与「Manage Snapshots」两项（F05+F07 门生效实证）
- 空 state 文案 + Add 按钮渲染
- create text 变量（UI_SMOKE_VAR/from-browser-1）→ 行渲染 `UI_SMOKE_VAR from-browser-1 text` ✅
- edit modal：key 输入框 disabled（不可变 UI 层实证）、type combobox disabled ✅
- create secret 变量（UI_SECRET_OK/s3cr3t-ui）→ 行渲染 `•••••••• secret`（R4 掩码点修复的运行时实证）✅
- delete 变量（UI_SMOKE_VAR）→ 行消失 ✅
- DB 实证：value 为 CryptoJS 密文（rev-c R5 复核）

## F01 Unique values only — 全过（含开关往返）

- 网格 canvas 渲染正常（People 表 Alice/A1，1 record）
- 列头菜单内联编辑打开：菜单项含「Unique values only」且 **switch aria-checked=true**（Code 列建列带 unique）
- **开关往返**：UI 关闭 → Update Field → API 复核 `Code.unique=false`（持久化实证）→ API 恢复 true
- 结论：F01 纯前端解锁的 UI 运行时行为完全正常

## F07 Snapshots — 部分（菜单/tab/深链 ✓，创建流待 R3 UI 路复测）

- 菜单「Manage Snapshots」可见（F07 门生效）
- 工作区列表可见历史快照副本 base（设计如此：副本是普通 base）

## 工具可用性结论（用户三问）

| 工具 | 状态 | 本地 dev 可测？ |
|---|---|---|
| camoufox-cli | ✅ 已装（CLI 0.7.3 + 浏览器 + UBO 手动补） | **是（主用）** |
| camoufox MCP | ✅ 服务可用，但服务端 SSRF guard 拦一切私有网段（localhost/127.x/100.x 实测三连拒）；公网隧道（trycloudflare）可达，但 CN 直连 CF 边缘不稳 | 需公网隧道（辅助） |
| browser-act | ✅ 已装（CLI 1.4.2，uv tool） | 否（云浏览器，结构性无法访问本机；仅公网 URL） |
| zcode 内置浏览器 | ✅（login 成功实证） | 是（备用） |

## 途中发现（非 F05/F01/F07 代码缺陷）

- 登录态在整页 reload 后偶发丢失（signin 重定向）——刷新令牌流在 dev http 下行为，绕法=登录后免刷新纯点击
- 网格为 canvas 渲染，DOM snapshot 无列头/单元格 → 需坐标/eval 驱动（已验证可行）
- antd Select 需 mousedown 事件开下拉（selectOption 不可用）
