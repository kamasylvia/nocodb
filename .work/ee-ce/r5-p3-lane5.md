# F09 P3 R5 修复回归(冲刺轮)— lane 5 报告(UI 验证重点路)

**结论:PASS(0 error + 1 minor + 1 观察)**

- 审查基线 = 45032e45b0(R4 修复批);HEAD = 33a13db54a(R5 dispatch)。后端 :8080 pid 72234(05:55 起)晚于 dist mtime(05:31),运行 dist 与工作区 dist md5 一致(10c3469c62997b30e26f90adffc71dca)— 活体口径成立。
- 账号 f09p3r5l5-{api,ui,ed}@lantest.local(UI/API 分离);camoufox session `f09p3r5l5`(owner)+ `f09p3r5l5e`(editor)。
- R4 lane3 E3(子代理无浏览器工具)本轮解除:camoufox-cli 0.7.3 本机直跑,UI 活体全部实测,17 张截图归档 `.work/ee-ce/f09p3r5l5-shots/`。

---

## 1. 质量门

| 门 | 结果 |
|---|---|
| `npx tsc --noEmit` | exit 0(`f09p3r5l5-tsc.log`) |
| `npx jest --testPathPattern 'Fork'` | **44/44**(3 suites,与基线一致;`f09p3r5l5-jest.log`) |
| Vite URL 编译法 | CreateNewSync 200 (59KB) / SyncMenuOptions 200 (36KB) / SyncStatusBadge 200 / useTableSync 200 / Overview 200 — 5/5 |

## 2. R4 error 修复回归(E1 resync 响应泄漏)— 活体过

- `POST /api/v2/meta/bases/:dst/table-syncs/:id/resync` 响应体 **70 字节** = `{"id":"job1w50uo3xdlj747","name":"table-sync-run","status":"syncing"}`,仅 id/name/status 三键。
- 泄漏 grep 全零:token 尾 12 字符 0 命中、`rawHeaders`/`_readableState`/`"socket"`/`xc-auth`/JWT 特征 `eyJ` 均 0 命中(修复前 ~35KB 含调用者活体 JWT)。
- 功能本体不受影响:job 真实入队(id `job1…`)、status=syncing→active 翻转、全量跑后 src=dest=1008 精确持平。源码 `table-syncs.service.ts:1132-1135` 净化 return 在位。

## 3. API 站位回归(P1+P2+P3 全矩阵抽查)

| 项 | 结果 |
|---|---|
| realtime 单插 r6 / bulk 数组 r7+r8 / 单行 update r1=999 / delete r3 | 全部 ~3s 内传播,src=dest 逐项持平 |
| paused 窗口三写(freeze → 插 r10 + 改 r1=555 + 删 r4 → resume) | 冻结期 dest 滞后 8;resume 后 9/9 追平,r1=555 / r4 消失 / r10 到达 |
| paused resync 守卫 | 400 `Sync is paused. Resume it before syncing` |
| AUTO 双档行为分野 | realtime 镜像 p1 秒级到达;manual 镜像不同步;manual Sync now(resync)后 p1 到达、1009 持平 |
| bulk 5000 上限 | 422 `Maximum 1000 entities are allowed per request`(上游既有,非 F09) |

## 4. UI 活体(camoufox,zh-Hans 界面)

1. **zh-Hans 全中文**:localStorage 注入后整界面中文;向导/树菜单/确认弹窗/状态行全部中文键无英文回落(截图 02-16)。
2. **向导 Automatically/Manually 双档**:step2「同步方法」双 radio(「自动使用 — 源视图在几秒内同步到镜像表」/「手动操作 — 只有当您点击"立即同步"时同步」),默认 Manually;选 Automatically 创建 → `sync_trigger=realtime` 落库;再跑向导默认 Manually 创建 → `sync_trigger=manual` 落库。树实时刷新(R6 修复保持)。截图 09/11。
3. **树菜单三态**:active =「同步表」+ 立即同步/暂停同步/转换为普通表/删除同步(截图 04);paused =「已暂停」+ 恢复同步替代暂停同步(截图 06);Syncing =「正在同步」(下条)。open watch 重拉正常(freeze 后重开菜单即显新态,旧值冻结不复现)。
4. **Syncing 守卫**:resync 全量跑(6008 行,~10s 窗口)内开树菜单 → 仅剩「正在同步」状态行,**立即同步/暂停同步/转换为普通表/删除同步四项全隐藏**(截图 07);窗口过后菜单恢复 active 全项。
5. **删除流三腿**:腿3 删非活动表 → URL 停在原 grid 不动;腿1 删活动表 → 自动跳剩余表 grid(渲染正常,1K 记录无空白);腿2 删最后表 → 归位 `/nc/<baseId>` 空态「暂无表格」。截图 13/14/15。
6. **Convert 确认弹窗中文**:标题「转换为普通表」+ 按钮「取消」/「转换为普通表」(截图 05);确认执行后:树图标转普通表、grid **不空白**(r1=555…bulk 全渲染 = P3 顺带修活体回归)、meta `synced:false`、sync 记录 404、镜像行写入 200(readonly 解除)。截图 16。
7. **editor Overview 卡 gate**:ed 账号(base editor)Overview 页 `proj-view-btn__create-new-sync` 不存在,卡区无表同步卡(P2-R3 修复保持);editor 树菜单仅 TABLE ID(list-syncs 403 → sync=null,无泄露通道,合历轮裁定)。

## 5. 发现

### M1(minor)enqueueSyncJob 的 req shim 未实施(R4 建议的纵深防御半程)
- R4 lane3 建议双修:响应净化(已做,`resync()` :1135)+ `enqueueSyncJob` 入队前把 `req` 替换为 realtime 同款最小 shim `{ user: { id } }`(:825-850 现仍将完整 `req` 原样放入 job.data)。
- 现状定级 minor 而非 error:HTTP 回显通路已闭合(本轮 70B 实测),job.data.req 仅存于进程内 fallback queue 对象,R4 已证「全仓无其它把 job.data 吐给 HTTP 的端点」;残余面仅内部日志/未来管理面误用。建议 backlog 化:补一行 shim 即与 realtime 路径(table-sync-realtime.ts :145-147 先例)对齐。

### OBS-1(观察,不计数)Syncing 窗口时序极短
- 6008 行全量 resync 仅 ~10s;1000 行 incremental 秒级。活体抓 Syncing 态需要 resync 全量窗口。非缺陷,记录给后续轮 UI 复验的窗口口径。

### OBS-2(观察,不计数)树菜单 overlay 检测口径
- `offsetParent` 对 fixed 定位 dropdown 返回 null,自动化检测菜单可见性须用 `getComputedStyle().display`;本轮两次误报「菜单打不开」均系检测方法问题(复测 display 口径全过),非产品缺陷。

## 6. 清理记录

- DST/SRC 两 base DELETE 200;bases 列表 `f09p3r5l5` 前缀残留 = 0(探针 sync / conv 普通表随 base 级联)。
- `.f09p3r5l5-*` token/uuid 文件、resync 响应转储(含 token)、bulk payload 文件全部删除;`f09p3r5l5-setup.sh` / `f09p3r5l5-run1.sh` 留作审计(内仅本地 dev 一次性测试账号口令,红线允许项)。
- camoufox 双 session 已 close;三账号行保留于 dev 实例(无用户删除 API,历轮口径)。

## 7. 产物

- 截图:`f09p3r5l5-shots/01…16`(workspace en 初态 → base zh → 菜单三态 → 守卫 → 弹窗 → 删除三腿 → convert)
- 脚本:`f09p3r5l5-setup.sh` / `f09p3r5l5-run1.sh`;日志:`f09p3r5l5-tsc.log` / `f09p3r5l5-jest.log`
