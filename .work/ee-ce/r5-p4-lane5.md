# F09 P4 R5（冲刺轮）— lane 5（UI 验证重点路）报告

**结论：PASS / 0 error + 0 minor**

（R4 error E1 修复回归活体全过，R4 全站位同规格复跑全过，UI 六项全过；未发现新 error / minor。）

审查基线 = b4849136e1（R4 修复批：两阶段共享 shadow drop + junction 收敛 sweep + dropMirrorLinkColumn 幂等）。dist 双条件核验：dist mtime 2026-09-22 03:57 < :8080 进程（pid 76261）启动 04:06:36 ✓；dist 内修复特征串命中（`F09 P4-R4` ×4、`droppedLinkRtIds` ×4、`droppedLinkSrcColIds` ×4、`convergence sweep` ×1，R2/R3 守卫串 `F09 P4-R2` ×2、`prohibitedSyncTableOperation` ×7 仍在）→ :8080 运行的确含 R4 修复批。

账号 `f09p4r5l5-{owner,editor,ui,uied}`（API/UI 分离：API 面走 owner/editor，浏览器活体走 ui/uied）；camoufox session `f09p4r5l5`。脚本：`f09p4r5l5-run1.sh`（E1 修复回归三场景，7/7 PASS）、`f09p4r5l5-run2.sh`（站位全矩阵，13/13 PASS）、`f09p4r5l5-ui-setup.sh`（UI 环境）。截图 16 张 `.work/ee-ce/ui-shots-f09p4r5l5/`。

## R4 E1 修复回归（活体，本轮重点，全部通过）

双 junction 共享 shadow 配置（源主表 2 个 mm link 列 T2s/T2s2 指向同一 RT，full-create 后 mappings=[main,linked_shadow,junction×2]，junction 配对 2/2）：

1. **场景 A · 删一条 link**（T2s 落选、T2s2 保留）→ PATCH **200**；镜像 T2s 列删、T2s2 列 id 不变；**共享 shadow 保留**（roles 保持 junction,linked_shadow,main）；存活 junction 配对 =2 不损；被删腿 junction 表已删。R4 症状「另一 link 三层拆毁/配对损失」零复现。
2. **场景 B · 一条 PATCH 删双 link** → **200**（R4 首发 404 `ERR_FIELD_NOT_FOUND` 不复现）；收敛后 roles=[main]，两 junction 表 + 共享 shadow 全删（均 404），镜像零 link 列，mapping 无孤儿。
3. **场景 C · 幂等/收敛**：同 PATCH 重试 200 收敛；二次重建后**分步两轮 drop**（先删 1 条→再删 1 条，后者走「column 元已删结构的幂等吸收 + sweep」路径）终态与场景 B 一致（roles=[main]、junction/shadow 全清）。

## P4 全站位继承（R4 同规格复跑，全部通过）

1. **三层 link sync**：createSync 三 mapping（main/linked_shadow/junction，junction `source_*=null`）；full-create junction 配对精确。
2. **updateSync 级联**：keep-link PATCH 三层不拆（mappings=3、shadow id 不变、mirror link 列 id 不变、junction 配对不变、**无 resync**——`last_synced_at` 不变）；源加 T2s2 → 加腿 PATCH shadow **共享**（4 mappings、shadow ×1）+ full-resync 自动回填（2/1=源 junction 镜像）；单 link 删级联 mappings=1；null PATCH 加回全字段含 link（4）；`[]` → 400。
3. **v3 通道守卫**：owner/editor 对 synced 镜像 `POST/DELETE /api/v3/data/:base/:model/links/:col/:row` → **422 ×4**；拦截后 junction 配对不变；合法路径不误伤（owner 源表 v3 POST/DELETE = 200、镜像 GET = 200）；v3 PATCH 镜像标量 = 400 readonly。
4. **paste 面**：browse sourceSchema 列 link（T2s、T2s2）；paste sourceSchema **不列** link；paste+link createSync → 400；paste 纯标量不误伤。
5. **AUTO realtime**：标量 p4 插入秒级传播 mirror；link 配对 tap → full-resync 自动回填（junction 总配对 3→4，无手动 resync）。
6. **窗口收敛**：realtime delete 档 mirror 行删 + junction 孤儿清（4→3，合法配对保留）；manual catch-up sweep（p2 删 → resync → mirror 无 p2）；**mark_deleted 档** mirror 保行 + `RemoteDeleted=true` + junction 总配对 2→0（两档一致清配对）。
7. **ACL**：editor 对 list/create/resync/patch/delete 五端点全 **403**；守卫链：editor 删镜像行 422、editor junction 直写 422。

## UI 活体（camoufox session f09p4r5l5，本路重点，全部通过）

- **zh-Hans 全中文界面**：语言经用户菜单 Language → 中文简体（localStorage `nocodb-gui-v2.lang=zh-Hans`）后，向导/树菜单/弹窗/网格全流程全中文零英文回落（截图 01-15 全程）。
- **向导三层 link 建同步全链**（截图 01-06）：owner Overview 可见表同步卡（`proj-view-btn__create-new-sync`）→ browse 选 base/table → specific 字段列表**含 link 列 T2s**（`data-testid=table-sync-field`，向导零改动自然可选）→ step2 双设置组（同步方法 自动/手动 + 删除记录 两档，全中文）→ 创建同步 → 树出现主镜像 + junction 表 → API 交叉核验 `roles=[main,linked_shadow,junction]`、status=active。
- **树菜单三态 + Syncing 守卫**（截图 07-10）：Synced（状态行 同步表 + 立即同步/暂停同步/转换为普通表/删除同步全项）→ 立即同步 触发后重开菜单 = **正在同步 且五项全隐**（截图 08，守卫实锤；后端同步确认 status=syncing→active、`last_synced_at` 推进）→ 完成后关开重开回 Synced（reload-on-open 生效）→ 暂停同步 → **已暂停**（恢复同步 现、暂停同步 隐，截图 10）→ 恢复同步 回 active。
- **删除流三腿**（截图 12-14）：leg1 删非 active 同步表 → active 表 URL 不变；leg2 删 active 同步表 → **重定向 remaining[0]**（URL 直达 sync_t3 镜像）；leg3 删唯一表 → **base home**（`/nc/<base>`，树显示 暂无表格）。
- **Convert 确认弹窗全中文**（截图 11）：标题 转换为普通表 / 正文含表名 / 按钮 取消 + 转换为普通表，零英文回落（弹窗验证后取消，未执行 detach，为删除流三腿保留现场）。
- **editor gate**：uied（editor）登录打开 base 被上游路由**直送镜像 grid**（无 Overview 页）；editor DOM 中 `proj-view-tab__overview` 不存在（creator-only ACL）；打开 synced 镜像 grid **「新增记录」按钮 `disabled:true`**（截图 15，DOM 实证 `nc-grid-add-new` disabled）。

## R4 小修验证

- processor catch-up 头注释准确：`table-sync.processor.ts` 无 "WITHOUT sweep" 残留语义（L342-346/L248-249 明确 catch-up 落 FULL pass 含 disappearance sweep）。

## 质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**63/63，3 suites 全过**（含 R4 新增 3 个共享 shadow drop 回归用例）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`：**5/5 过**（环境注：本机 nuxt dev 常驻高负载下 worker/beforeAll 首两次超时，`--pool=threads --maxWorkers=1 --hookTimeout 300000` 单跑通过；R4 已知「并发抖动单跑过」同象，非代码回归——基线 b4849136e1 未触及 nc-gui）。

## 观察与瞬时项（非判定项）

- run2 首轮一次 null PATCH 返回非 sync 对象：上一步删腿的 full-resync 尚未收敛时 PATCH 撞 busy 守卫（守卫行为正确），等待重试即过；属测试时序竞态非产品缺陷，复跑 13/13 稳定。
- Paused 态菜单保留「立即同步」（菜单 v-if 仅排除 Syncing）——R4 同观察，维持既有菜单设计判定，非本轮引入。
- 测试脚本 v3 合法路径/守卫 URL 首轮混入 v2 形状 `records` 段致 404（Express 路由 404 非守卫触发），修正 URL 形状后全过——v3 links 路由真身 `/api/v3/data/:baseName/:modelId/links/:columnId/:rowId`（`PREFIX_APIV3_DATA='/api/v3/data/:baseName'`）。

## 未覆盖（环境/范围限制，非「通过」）

1. Convert 弹窗实际 detach 执行路径（确认后 sync 清零/表转正）：为删除流三腿保留 3-sync 现场而取消弹窗；detach 活体已由 R4 lane5 截图 11-12 覆盖且本轮零相关代码变更。
2. UI link cell 写路径的 422 toast 文案（后端 422 已由 API 活体覆盖）。
3. 测试账号删除：无删除用户 API，`f09p4r5l5-{owner,editor,ui,uied}` 保留（全前缀可辨，历轮同惯例）。

## 纪律

只读审查（`git status`：跟踪文件零改动；仅新增 `.work/ee-ce/f09p4r5l5-*.{sh,log}`、本报告与 `ui-shots-f09p4r5l5/` 截图）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`；无 psql、未提权；隔离未读他路 R5 报告（对照材料限任务书指定：r5/r4/r3 lane-prompt、r4-p4-lane5、R4 修复批 commit）。测试数据清零：`f09p4r5l5` base 计数 = 0（清零核验 7/7 删除 200）；camoufox session 已关闭；无凭证写入 git 跟踪文件（口令仅存 `.work` 白名单脚本，历轮惯例）。
