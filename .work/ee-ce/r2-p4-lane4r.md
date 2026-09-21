# F09 P4 R2 修复回归 — lane 4r 报告

**结论：PASS（0 error + 1 minor）**

- 基线：HEAD d22a2b78a8（含 R1 修复批 5368ef1366，src 树零 builtin 修改）；:8080 运行 dist 含 R1 批（`assertLinkWriteAllowed`×6 在 dist 内，构建 09-20 10:08，进程 10:15 起，未动构建/重启）
- 账号：`f09p4r2l4r-api`（workspace-creator+两库 owner，经 f01e2e-super invite 提权）/ `-ed`（DST editor）/ `-paste`（源零成员，DST owner 仅为建 sync）/ `-ui`（UI 专用）；camoufox session `f09p4r2l4`（已关）；注：`f09p4r2l4-*` 被并发方占用（口令冲突），本路全用 `4r` 前缀隔离
- 脚本：`.work/ee-ce/f09p4r2l4r-{setup,run1,run2,run3}.sh`；截图 `f09p4r2l4r-{treemenu,zh}.png`
- 测试库 SRC/DST 全删（404 复查，残余 4r 表 0）；账号保留可复测

## R1 四族回归（活体，run1-3：38/38）

1. **updateSync 级联**（R1 lane1/3b/4b/5 E1）：keep-link PATCH（去 Qty 留 Ns）→ Ns 列 id 不变、mappings=3、junction=2 保留；加腿 Ns2 → **自动 full-resync，配对 2+1=3（无手动 resync，R1 静置 0 不复现）**；null → mappings=4（保留 Ns + 补齐 Ns2）；`[]` → 400（`selectedFields must be a non-empty array or null`）。PASS
2. **双 shadow 共享**：同批 create [Ns,Ns2] → 1 shadow + 2 junction；updateSync 加腿复用既有 shadow（仍 1）；单删 Ns2 → shadow 保留（Ns 仍引用）+ Ns2 junction 拆；源列改名→resync 配对不断（2 行 intact，id 键控）。PASS
3. **LTAR 守卫**：editor 注入→422（`ERR_SYNC_TABLE_OPERATION_PROHIBITED` 同族）、owner 注入→422、editor 解除真实配对→422、junction 直写→422、篡改后 junction=2 未动。audit-replay 放行 + removeChild/removeLinks/reorderLink 入口 = 单测覆盖（spec 4 用例）；引擎通道：live 回填/realtime 全正常，无 bypass。PASS
4. **paste 拒收**：paste+link → 400（消息含 browse-mode 说明，见下）；paste sourceSchema 仅 `[Title,Qty]`；paste 纯标量 → 200；i18n key en+zh 在位（`msg.warning.syncPasteLinkUnsupported`）。PASS（接 M1）
5. **deleteSync**：常规级联活体（4 表 + sync 行全 404）；僵尸守卫（主镜像删失败保 sync 行）= 单测 2 用例 + 代码面（live 不可伪造 tableDelete 失败，未触发，声明）。PASS（单测覆盖）
6. **mark_deleted 两档**：realtime 删 p3（无配对）+ p1（2 配对）→ incremental 标 flag=2 且 junction 2→0；resync full 档仍 0（统一）。另：源加 link → realtime tap 全量，junction 0→1（无手动）。PASS

## P1-P3 站位（抽查 + 单测）

- 标量全链：mirror=3、更新传播（n1u）、delete 策略 sweep 3→2；realtime 标量 ~20s 出镜（nRT）；AUTO 双档（manual s1/s4 + realtime s3/s5 并存）；守卫链（镜像 PATCH 400/editor 400/无源成员直读 403）；detach 转正（synced=false、可写 200）
- E1 六格 / ACL 十一端点 / 守卫链矩阵：API 抽查（editor 建 sync 403、link 422、镜像 400、越权 403）+ jest 60/60 全覆盖，不逐项重跑
- 观察（非问题）：T2 逆向 mm（T1s/T1s1）属 syncable（mm 双向 + 同 base + 非自引用），向导/API 建三层均 active——设计一致

## UI 活体（session f09p4r2l4）

- 向导：browse 选 SRC→T2→字段（Name/Secret/T1s/T1s1 渲染）→ 建 sync `T2 [T1s]` → main+shadow+junction active（三层 link 建同步 UI 闭环；probe-hm API 同构复核）
- 树菜单三态：Active（Synced table + Sync now/Pause/Convert/Delete，截图）→ Pause 生效（status=paused）→ 菜单切 Paused（Resume 出现）；删除流：确认框 → sync 404 → 树节点消失
- editor 门：无 Create 入口、镜像 New record disabled、节点菜单仅剩 TABLE ID（API 侧 403/422 已验）
- zh-Hans：语言切换 → 数据/设置/帮助/活动（截图）

## M1（minor）：`syncPasteLinkUnsupported` key 无组件引用

- nc-gui 内零 `.vue/.ts` 引用该 key；paste+link 400 运行时消息 = 后端英文原文（活体实测），zh 用户看到英文。key 已备（en+zh 文案对），只差 wiring。建议：CreateNewSync  catch 后按该 key 渲染，或后端按 req locale 选文案。

## 质量门

- `tsc --noEmit` exit 0；jest Fork **60/60**（3 suites，ERROR 行系预期负路径日志）；lang JSON 双文件可解析；Vite：R1 零 SFC 改动（lang-only），门无对象（同 R1 口径）

## 清理

- DST/SRC DELETE → 404；bases 列表 4r 残余 0；token dotfile 留 /tmp（本机）；源码零改动（`git status` 仅 .work 未跟踪脚本/png）
