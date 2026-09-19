# r4-p3-lane5 — F09 P3 R4 站位回归审查报告（UI 验证重点路）

**结论：PASS / 0 error + 1 minor**（streak 2/3）

- 审查基线：8de55d0b24（R3 后零代码功能变更，仅 zh-Hans 键补齐 + 注释清理）；HEAD 4f13fd293f 仅 .work 派遣件
- 后端 :8080 全程就绪（未构建/未重启/未自愈，只读审查）；前端 dev :3000（IPv6-only 监听）
- camoufox session `f09p3r4l5`（camoufox MCP 本轮不可用，按 §7 回退本机 camoufox-cli）
- 报告与截图：`.work/ee-ce/r4-p3-lane5.md`；截图 `.work/ee-ce/f09p3r4l5-shots/`（33 张）

---

## 1. 质量门（三项全过）

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit`（packages/nocodb） | exit 0，0 error |
| `npx jest --testPathPattern Fork` | **44/44**（3 套件，41.9s） |
| Vite URL 编译法（localhost:3000 `/_nuxt/@fs/`） | 4/4 = **200 text/javascript 真产物**：CreateNewSync.vue / SyncMenuOptions.vue / useEeConfig.ts / useTableSync.ts |

产物锚点双确认：SyncMenuOptions 产物内 `isConvertConfirmOpen` ×7 + `table-sync-convert-confirm` testid；useEeConfig 产物内 `blockTableSyncAuto = computed(() => false)`（AUTO 解锁在）；lang/zh-Hans.json 产物内 `convertToRegularTable: "转换为普通表"`（dev server 供给的是新键）。

## 2. R4 增量：Convert 确认弹窗 zh-Hans（活体，PASS）

- 源码锚：`zh-Hans.json:1432` `"convertToRegularTable": "转换为普通表"`（8de55d0b24 新增）；SyncMenuOptions.vue 弹窗标题与确认按钮均 `$t('labels.convertToRegularTable')`
- 活体（zh-Hans 界面，账号 f09p3r4l5-ui）：树菜单项显示「转换为普通表」；弹窗**标题**「转换为普通表」、正文 `f09p3r4l5_src — "f09p3r4l5_src"`、**确认按钮**「转换为普通表」——标题/按钮两处均不再回落英文（shot 17/18/20）
- 不动作验证：**Esc** 关弹窗且不转换（sync 仍在）；**Cancel** 同验证（shot 21 后 `table-sync-menu-status` 仍在）
- 真转换（Confirm）：sync 移除、表保留——grid **不空白**（1005 行满渲染）、「新增记录」按钮恢复可用、Title 列 ⚡ 标消失、树图标转普通表（shot 27）；P3 顺带修（detach 后 getMeta 强刷 + loadViews force）在 R4 产物中站位生效

## 3. 站位全回归 — API 面（`.work/ee-ce/f09p3r4l5-run1.sh`，最终 **33/33 PASS**）

realtime sync（src1→dst1, onDelete=delete, syncTrigger=realtime）：

- **realtime 四写**：单插亚秒级传播；单改 Qty=999 传播；**数组 bulk 插 3 行传播**（E-bulk 站位）；delete 腿源删→镜像删、无 ghost
- **Syncing 窗口三写收敛**：源喂至 406 行 → resync 窗口内（status=syncing 时）发 patch/insert/delete 三写 → 当轮结束 catch-up（R2 起为全量 pass 含消失扫描，processor.ts:321-326 注释与实现一致）→ **insert/update/delete 全部收敛**，窗口捕获本身亦命中（status 轮询命中 syncing）
- **paused 窗口三写收敛**：freeze→插/改/删三写→resume→**resume 即触发补齐跑**（status 短暂 syncing 后回 active）→三写全追平含 delete 腿（R1 ghost 场景零复现）
- 幂等复跑 406→406；`hourly` → 400 Invalid sync trigger
- 守卫链：镜像直插/直改 → 400/400（普通写路径拒）
- selected_fields：`selectedFields:[Title]` 镜像无 Qty；**camelCase PATCH** `selectedFields:[Title,Qty]` → resync 增列传播
- 类型漂移：源 Qty `Number→SingleLineText` patch 200 → resync → 镜像 uidt 跟随
- ACL：editor 角色 createSync/freeze/resync/delete-sync 全 **403**，读镜像 **200**
- paste 链：共享视图 uuid → `sourceInputMode:paste + realtime` 建同步 → full-create 镜像=2 → 源插实时传播
- detach：POST detach → sync GET 404、镜像 `synced=false`、转正后可写 200

## 4. UI 活体清单（camoufox，全部真截图）

| 项 | 证据 | 结果 |
|---|---|---|
| 登录 + zh-Hans 切换 | `nocodb-gui-v2.lang=zh-Hans`，界面全中文 | ✓ |
| 源 base 搭建（UI 驱动） | UI 建表 f09p3r4l5_src、canvas 网格录入 row-a/row-b/row-c（shot 01-06, 15） | ✓ |
| allow_sync Share 入口 | 启用公开查看后「允许同步」开关出现并开启（isPublicShared=uuid 语义）（shot 08） | ✓ |
| **向导双模式** | step2「自动使用/手动操作」双 radio 可选、默认手动；Automatically 建 mirror1（shot 10/11）、Manually 建 mirror2（shot 26）/mirror3/4 | ✓ |
| **realtime UI 写入传播** | 源 grid UI 加 row-c → 镜像出现（shot 16，同帧含「创建记录受限/无法在同步表中创建记录」镜像只读守卫 tooltip） | ✓ |
| **realtime 1000 行 bulk 自动追平** | 浏览器 fetch（:8080 + token，content-type=application/json 验真）插 1000 行 → 源 1005 = 镜像 1005 | ✓ |
| **树菜单三态** | Active：同步表+立即同步/暂停同步/转换为普通表/删除同步（shot 17）；Paused：「已暂停」+恢复同步项替换（shot 22）；Syncing：「正在同步」+ syncnow/convert/delete/freeze **DOM 断言全 false**（shot 24/25 菜单在画面内仅剩状态行） | ✓ |
| **Syncing 守卫** | 1000 行 Sync now 窗口内菜单打开即命中上述守卫态 | ✓ |
| **删除流三腿** | leg3 删非活动（src2）URL 停原表（shot 28）；leg1 删活动（src3）跳 remaining[0]=src（shot 29）；leg2 删最后一张（src4）归根本页 `/nc/p6033am4ctp19ci`（shot 30）——R8 storeToRefs 修复三腿全存活 | ✓ |
| **editor Overview 卡 gate** | editor 开空 base Overview：**「无可用操作」**，表同步/创建新表卡全缺席（shot 33，对照 owner 视图 shot 09 四卡）；API 侧 editor createSync 等 403 呼应 | ✓ |
| Convert 真转换 grid 站位 | shot 27（见 §2） | ✓ |

## 5. Minor（1，不阻塞，不升 error）

**M1 树节点瞬态残留（reload/重进自愈）**：两处同根现象——① Convert/detach 完成后 dst 树一度渲染 6 行（含已转正表的 ⚡ 重复行；服务器 meta 始终正确 4 表，shot 27 可见）；② 跨账号登出/登入后 editor 首开 ui-src，树短暂出现 📁+⚡ 双行同名节点（shot 31），reload 即恢复单行（shot 32，服务器 1 表已验证）。判读：树 store 在 removeMeta/loadTables 与账号切换后的清理时序残留，与 P3 已修的「grid 瞬空白」同族——grid 侧已修净，树侧残留尚在。不阻塞功能（无幽灵数据、无错误交互），建议 P4 或收尾批顺带查树 store 同步。

## 6. 环境观察（不计产品 minor）

- camoufox 浏览器内裸 `fetch` 相对路径 `:3000/api/...` 会被 Nuxt dev server 兜底返回 **200 HTML**（假成功）——bulk 首插因此空转一轮；改绝对 `:8080` + localStorage token（content-type=application/json 验真）后正常。后续 lane 用浏览器 fetch 时必须验 content-type。
- 一次运行轮（v3）中 T10/S9 的 infra 建 base/share 调用在 400 行 resync 负载下瞬时失败（jqget 输出 "null" 串入 URL 的假象）；加 retry 后 v4/v5 全绿——远端 PG（Tailscale）负载瞬时抖动，非 F09 代码问题。
- 测试脚本自身缺陷（PATCH/DELETE v2 body 形状、分页扫首 5 行误判收敛）曾在中间轮产生假 FAIL，最终轮以正确形状（PATCH 平铺含 Id；DELETE 行对象数组 `[{"Id":".."}]`）+ where 计数轮询全数排除；这些 FAIL 均非产品问题。

## 7. 测试数据清理（已执行）

- API 侧 base（src1/dst1/src2/dst2）脚本自清理；UI/ed base（ui-src `pyj5xx1bh6wtmo3`、ui-dst `p6033am4ctp19ci`、ed-empty `paj7rrx5nfh2kyq`）infra 删除 200×3；`startswith("f09p3r4l5")` 清单复核 **0 残留**
- 账号保留（f09p3r4l5-api / -ui / -ed@ce-ee.local，与此前轮惯例一致，可复用）；camoufox session `f09p3r4l5` 已 close

## 8. 截图索引（`.work/ee-ce/f09p3r4l5-shots/`）

01-06 源表搭建/数据录入；08 allow_sync 开启；09 owner Overview（四卡对照）；10/11 向导 step2 双档+选自动；12-16 镜像创建/row-c 传播/只读守卫；17 树菜单 Active；18/20 Convert 弹窗中文（菜单叠开/完整标题）；21 Cancel 后；22 Paused 态；24/25 Syncing 守卫（DOM 断言+菜单画面）；26 手动档创建；27 Convert 真转换 grid 不空白；28 leg3 停原表；29 leg1 跳剩余；30 leg2 归根本页；31/32 editor 树残留+自愈；33 editor Overview 卡 gate。
