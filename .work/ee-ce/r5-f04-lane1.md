# F04 R5 复审报告 — lane 1(2026-09-17,重派独立重审)

PASS(0 error)

基准:HEAD = 1480308312(含 R4 修复 9188e0f1ff + R5 修复批 64b720d877)。审查全程只读源码,测试资产用 f05r5l1-* 前缀,已清理。所有结论基于本轮独立实测,证据齐全。

## R5 专属增量验证(核心)

### 1. resync 乐观置位锁(R4 commit 9188e0f1ff)— 实测通过
- 代码:`Sync/index.vue:147-151` — guard(141-146)在前,`syncingId.value = row.id` + 乐观状态置位在 trigger POST(153)之前。
- 实测(camoufox owner 会话,`performance.clearResourceTimings()` 后同 tick `btn.click()` ×2):
  - `performance.getEntriesByType('resource')` 过滤 `atImportTrigger` → **triggerCalls: 1**(URL `/v2/internal/:ws/:base?operation=atImportTrigger&syncId=...`)
  - toasts:`["Syncing…"]`(第二击命中 guard 弹 info toast)
  - 状态行乐观显示 "Syncing…",按钮未靠 disabled(`resyncDisabled: null`),靠 guard 拦截
- 结论:**同 tick 双击仅 1 发 atImportTrigger,不依赖后端 400 去重** ✓

### 2. 锁释放路径完备 — 实测 + 代码审通过
- **FAILED(实测)**:伪凭证 job 秒失败 → 轮询捕获 `status:"failed"` → 状态行 "Sync failed"(红,`text-nc-content-red-medium`)+ 自动解锁;解锁后再点 Resync → performance 计数新增 1 发 ✓
- **catch(实测,R5 修复批 64b720d877)**:API 删除 sync 行(DELETE 200)后点该行 Resync → 后端 400 `"Sync Source 'ncxarz3t5pzb3p98' not found"` → 状态行显示**红色错误消息**(非 "Syncing…" 残留)+ error toast;按钮解锁 ✓
- **timeout(代码审)**:`Sync/index.vue:194-200` polls>=30 → clearInterval + watchdogTimers 过滤 + syncingId=null + `labels.syncsSyncTimeout` 文案 ✓
- **COMPLETED(代码审)**:181-185 同款三连清理;真实完成链路受 fork 限制无法实测(E3)

## R4 增量回归

1. **watchdog 卸载清理**:onUnmounted 全清 watchdogTimers(`:44-47`);ProjectSync 为普通 v-if 挂载、无 keep-alive(`View.vue:584`),settings 导航离开实测面板卸载(`.nc-base-syncs` 移除),重进渲染正常 ✓
2. **二次 resync 反馈**:guard 命中弹 "Syncing…" toast(R5 双击测试中实证)✓
3. **90s 超时文案**:en `"Still syncing after 90s — check back later or retry."` / zh `"90 秒后仍在同步——请稍后回来查看或重试。"`,均无 "job list"/"job" ✓

## 全矩阵

### diff 审查
F04 系列 commit `2fd09efccf`(实现)+ `dbfefe5a63`(R1 修)+ `b6c95cb3ac`(R3 修)+ `9188e0f1ff`(R4 修)+ `64b720d877`(R5 修)逐个 `git show --stat`:改动仅 nc-gui 前端 6 文件 + lang 双份 + .work 文档;**packages/nocodb/src 零变更** ✓。store/sync.ts / utils/syncUtils.ts F04 系列零 diff ✓。

### gate 状态
- `useEeConfig.ts:158` `blockSync = computed(() => false)` ✓(相邻 blockTableSync 改动属 F09,非 F04)
- `View.vue:572` tab `!blockSync && isUIAllowed('sourceCreate') && base.id && !isMobileMode`(F07 snapshots 模式,badge 改 feature-enabled-callback)✓
- `View.vue:175` `?page=syncs` watch 已去 isEeUI ✓
- `BaseSettingsMenu.vue` syncs 项同模式 + badge;导航 gate `showUpgradeToUseSync`(no-op)未动 ✓

### i18n
16 键(labels.manageSyncs + syncs* 15 键,含 DetailsJson / DeleteDescription `{title}` 插值)en + zh-Hans 双份齐备,与组件 t() 一一对应 ✓。

### ACL/角色矩阵(API 实测)
- creator:GET/POST/PATCH/DELETE syncs 全 200 ✓
- editor:list=403 create=403 patch=403 delete=403 ✓
- 匿名:list=401 create=401 ✓

### CRUD e2e(API)
create(Airtable+details)×2 → 200 → list 含 2 行 → PATCH title+details → 200 落库(details.note 回读 "patched")→ DELETE → 200 ✓

### trigger 路径
internal op `POST /api/v2/internal/:ws/:base?operation=atImportTrigger&syncId=` → 200 `{id:"jobp…"}`(证实 `jobData?.id` 存在,面板轮询走 targetJobId 精确分支);伪凭证 job 终态 `status:"failed"`(与 `JobStatus.FAILED='failed'` 小写枚举一致,`nc-gui/lib/enums.ts:126-134`)✓

### UI 段(camoufox,owner)
侧栏 Manage Syncs 菜单(`[data-testid="base-syncs"]`,含 UpgradeBadge)→ 点击导航 → 面板渲染(tabpanel)→ 空态文案 → API 预建行后 reload:卡片(title / type / details 键 `apiKey · baseId · note` 展示)→ Edit(表单预填 title+JSON)→ 改 title 保存 → toast "Sync source updated" + 列表刷新 → Delete(Modal 文案含 `{title}` 插值)→ 确认 → 行消失 + toast → 回到空态 ✓;console error 零、无 Nuxt overlay ✓

### editor UI 隔离
settings 侧栏无 Manage Syncs 菜单项(`[data-testid="base-syncs"]` 不存在);直航 URL `#/nc/:baseId/settings/syncs` 面板不渲染(无 `.nc-base-syncs`);console error 零、无 overlay ✓

### App Sync 隔离
`isSyncFeatureEnabled` 全仓唯一赋值 `store/sync.ts:19 ref(false)`,F04 未触碰;三消费组件(IntegrationsTab / AddConnectionDropdown / base Integrations)保持 false 分支;UI 探针 integrations 页无 App Sync 入口文本 ✓

### 回归 smoke(creator API 探针)
F02 `/permissions` 200;F05 `/variables` 200;F07 `/snapshots` 200;F08 base meta 200;F10 `/dashboards` 200;v1 base meta(AirtableImport 依赖)200。F03 未实现,gate 面未被 F04 触碰 ✓

### 质量门
- `cd packages/nocodb && npx tsc --noEmit` → **exit 0**
- jest → **41/41 通过**(3 suites;原基线 26 + F09 table-syncs.Fork.spec 15;F04 后端零改动无新 spec)

## 观察项(非 error)

1. `Sync/index.vue:141` guard 用全局单值 syncingId(非 per-row):A 行同步中点 B 行 Resync 同样被 "Syncing…" 挡。可辩护(避免并发 job 状态互踩),与 R4 验收口径一致,不改。
2. **base 删除不级联删 `nc_sync_source_v2`**:删 base(200)后 sync 行残留(本轮 nocodb-dev 只读查询实证,已手动清理)。上游级联清单(Source 删除/用户删除,研究 §3.1)不含 base 删除,属上游行为、与 F04 面板无关;记录供上游对照/清理脚本参考。
3. editor 直航 syncs URL 时 base 顶栏标题显示 "Manage Syncs"(title map 取 route)——R3 已知非问题(上游框架)沿袭;面板本体不渲染、无 ACL 泄露。
4. 本轮 UI 实测走 :3000(Nuxt dev);:8080 当前无前端 bundle(`GET /` → Cannot GET,AGENTS §3 已知现状)。

## E3(不计 error)

- 重同步 COMPLETED 全链路需真实 Airtable 凭证(fork 限制,研究 §7);FAILED/timeout/catch 路径已覆盖实测。
- FAILED 详情恒泛型 "Sync failed"(jobs API `result:null`,上游 setJobResult 零调用,沿袭已知非问题)。
- dev 库存量测试账号噪声(沿袭);共享 super 账号 f03r3-owner 的 token_version 并发轮转致间歇 401(互踢机制,纪律已知,已用 lane 专属账号规避)。

## 测试资产清理(仅本轮 f05r5l1 自建)

- base p2vpq931a4w87py(f05r5l1-base,含表/sync 行)→ DELETE 200;残留 sync 行经 nocodb-dev 只读连接确认后删除(1 行)
- 用户 f05r5l1-owner2 / f05r5l1-editor / f05r5l1-owner → super API DELETE 200×3(成员关系行同步清理)
- /tmp 下 f05r5l1-* 脚本与 token 文件已删;camoufox session f05r5l1 已 close
- 注:DB 存在上一批 R5 遗留 `f05r5l1-<role>-<ts>@t.local` 账号(28 个,非本轮创建),按「只动自己前缀数据」谨慎口径未动,留 orchestrator 处置
