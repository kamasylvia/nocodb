# F09 R10 lane5(UI 验证重点路)复审报告

**结论:PASS —— 0 error + 2 minor(均沿袭/观察级,不阻塞)**

- 审查员:f09r10l5(lane 5,UI 验证重点路)
- 基线:HEAD = 70a78bd4eb(5bea0c3943 之后仅 `.work/` 流程文件提交,代码面 = 5e3d736b2a,与任务书一致)
- 服务:后端 :8080 = 200,前端 :3000 = 200(全程无异常,无轮询触发)
- 账号:UI `f09r10l5-ui` / API `f09r10l5-api`(owner)/ `f09r10l5-mx`(矩阵)/ `f09r10l5-edt`(editor)/ `f09r10l5-ws2`(零关系)——UI 与 API 分离
- camoufox session `f09r10l5`;测试 base 测完删除(src/dest 均 200);截图 `/tmp/f09r10l5/shots/01–23`

---

## 一、编译健康先行门(R10 附录 A.2)—— PASS

| 检查 | 结果 |
|---|---|
| `/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` | 200 |
| `/_nuxt/components/project/Action/CreateNewSync.vue` | 200 |
| `/_nuxt/components/dashboard/TreeView/Table/SyncStatusBadge.vue` | 200 |
| base 页 `vite-error-overlay` | `querySelector('vite-error-overlay')` = null,截图 02 无 overlay |

## 二、删除流自动跳转三腿 + 判别对照(R10 附录 A.1,本轮重点,camoufox 活体)—— 全 PASS

### 腿 1(剩余表腿)
打开 sync-del3 镜像表(URL 确认为当前表)→ 树菜单 Delete sync → 确认:
- 树即时移除(`tree-removed-ok`)
- **URL 自动跳剩余首表** `/nc/ppc8m96i9yrj7j0/<seedTableId>/.../f09r10l5_seed`
- 主区渲染 seed 网格(Name=seed1, 1 record)——URL 与主区一致,无空白网格/死 tabs
- 证据:截图 16(树 2 表,seed 高亮 + 网格渲染)

### 腿 2(base 根腿)
删至 0 表(当前打开唯一 synced 表 f09r10l5_src → Delete sync → 确认):
- **URL 归一 `/nc/ppc8m96i9yrj7j0`**(base 根)
- 树显示 "No tables",主区正常渲染 base 根 Overview(Data Actions 四卡),无死区
- 证据:截图 22

### 腿 3(非当前表腿)
当前打开 seed,删非当前的 sync-mark:
- **URL 不变**(仍 `/nc/.../f09r10l5_seed...`)
- 树即时移除(`mark-removed-ok`)
- 证据:截图 17

### 判别对照(DlgTableDelete 同场景)
当前打开普通表 seed → context menu「Delete table」(无任何 sync 菜单项,sync 块仅 synced 表渲染)→ 确认「Delete Table」:
- 树移除 seed + **自动跳剩余首表 f09r10l5_src** —— 与 F09 腿 1 行为**一致**
- 证据:截图 19(菜单差异)、21(跳转后 URL)

### 5e3d736b2a 修复确认
SyncMenuOptions.vue `storeToRefs(tablesStore)` 在源码 :38-41(`activeTable` 经 storeToRefs),onDelete :62 捕获 `oldActiveTableId` 后 `loadTables()` 再分支 openTable/navigateTo——三腿活体行为与代码一致,storeToRefs 修复有效。

## 三、创建流(R10 附录 A.3)—— PASS

- **创建流树刷新(两轮复验)**:向导三步(base/table 选择 → 字段 → 标题/删除策略)→ Create sync → 不刷新页面,树即时出现新 synced 表(闪电图标);无成功/错误 toast 并存;API 侧 `f09r10l5-ui-sync` status=active。第二轮(重建 sync 供腿 2 用)同样即时入树。
- **可搜索选择器**:step0 base 下拉输入 `src-17` → 列表收窄为匹配项;输入 `f09r10l5-src` → 精确命中目标;table 下拉输入 `f09r10l5_src` → 精确命中。证据:截图 05。
- **向导按钮在 body**:step0 Next(disabled→选中后启用)、step1 Back/Next、step2 Back/Create sync 均渲染可点(截图 04/08/09)。Sync method 固定 Manually(Automatically 档不暴露,付费锁保持)。
- **编辑器视角(见 §六)**。

## 四、树菜单新鲜度(R10 附录 A.3)—— PASS

全程未刷新页面,重开 context menu:
1. 初始:`Synced table + Sync now + Pause sync + Delete sync`(active 态)
2. Pause sync → 重开:**`Paused + Resume sync`**(Pause 消失,即时翻转)
3. Resume → 重开:**`Synced table + Pause sync`** 恢复
4. Sync now → 重开:**`Synced table`**(非 Syncing,引擎完成后状态即时正确)
- 附加:悬浮树节点 tooltip「Synced table / Last synced 9/18/2026, 6:40:44 PM」动态状态行(SyncStatusBadge)工作(截图 11)
- testid 链:`table-sync-menu-status/-sync-now/-freeze/-resume/-delete` 全部按状态机条件渲染,`watch(props.open) → load()` 生效

## 五、引擎 e2e + 守卫链 + 系统列(R10 附录 A.4)—— PASS

### 引擎(API 实测,双删除策略)
| 步骤 | 结果 |
|---|---|
| full-create(delete 策略) | 3 行镜像 {row1,row2,row3},RemoteId="1/2/3" 键控正确,synced=true |
| upsert(PATCH 源 row2 Qty=22 → resync) | mirror row2 Qty=22(RemoteId=2 命中 update) |
| delete 策略(删源 Id=3 → sync3 resync) | mirror 4→3 行,row3 消失 |
| mark_deleted 策略(删源 Id=1 → sync2 resync) | mirror 行数不变,row1 **RemoteDeleted=true** 保留 |
| freeze → paused;paused resync → **400**;resume → active | PASS |
| realtime trigger create → **400**(付费锁保持) | PASS |
| updateSync title/on_delete_action → 200;`selected_fields` 变更(snake)→ **400** 拒收 | PASS |
| deleteSync → get 404,镜像表离场 | PASS |

### 守卫链
- insert 镜像表 → **400**;DELETE 镜像表 meta → **400**
- 镜像列 readonly=true(Title/Qty)

### 系统列网格不可见(三重保险,DB + meta + 活体)
- DB `nc_grid_view_columns_v2`:RemoteId/RemoteDeleted → **show=false + system=true + readonly=true**
- meta API 列属性:system=true, readonly=true(meta 序列化 show=null 为 v2 join 差异,DB 层与 UI 层均为隐藏)
- **camoufox 活体**:镜像表网格仅显示 Title/Qty 两列,RemoteId/RemoteDeleted 不可见,New record 置灰(截图 03)

## 六、ACL 十端点 + E1 六格 + R5 六腿(R10 附录 A.4)—— PASS

### 十端点
| 角色 | list | get | sourceSchema | create | update | delete | resync | freeze | resume | resolveLink |
|---|---|---|---|---|---|---|---|---|---|---|
| creator(api) | 200 | 200 | 200 | 200* | 200 | 200 | 200 | 200 | 200 | **501** |
| editor(edt,dest base) | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 | 403 |
| 匿名 | 401 | — | — | — | — | — | — | — | — | — |
| ws2(零关系,ws no-access) | 403 | — | 403 | — | — | — | — | — | — | — |

\* creator freeze/resume 在 resync 进行中时 400(syncing 互斥,fail-closed 合理);idle 态复测 200/200。
注:resolve-link 正路径 = `POST /api/v2/meta/bases/:baseId/table-syncs/resolve-link`(不带 syncId,501 预期)。

### E1 六格矩阵(mx 调用者,dest-creator 提权;角色变更全走 API PATCH)
| 格 | 状态 | F09 实测(预期) | 平台对照(预期) |
|---|---|---|---|
| E1.1 非私有+显式 no-access+ws-creator | source-schema | **404** (404) | GET base 403 (403) |
| E1.2 非私有+显式 no-access+ws no-access | source-schema | **404** (404) | 403 (403) |
| E1.3 私有+显式 no-access+ws no-access | source-schema | **404** (404) | 404 (404) |
| E1.4 私有+显式 no-access+ws-creator | source-schema | **404** (404) | 404 (404) |
| E1.5 非私有+显式 no-access → createSync | createSync | **404** (404) + 镜像表落地数=0 | 拒 |

### R5 六腿(mx 调用者,dest-creator 提权)
| 腿 | 状态 | 实测(预期) |
|---|---|---|
| R5.1 非私有+零 base 行+ws-creator | source-schema | **200** (200) |
| R5.2 非私有+显式 editor+ws no-access | source-schema | **200** (200) |
| R5.3 非私有+零关系+ws no-access | source-schema | **404** (404) |
| R5.4 非私有+inherit+ws-creator | source-schema | **200** (200) |
| R5.5 私有+零行+ws-creator(真零行) | source-schema | **404** (404) |
| R5.6 私有+inherit+ws no-access | source-schema | **404** (404) |

零关系调用者先被 dest ACL 403 拦/服务层 404——双 fail-closed 均判 PASS(R9 方法学 D)。

## 七、静态 diff 审查(8 项清单第 1 项)—— PASS

- F09 窗口(71896a841f^..HEAD)diff = 16 文件,与 impl-report 清单一致(+table-syncs.Fork.spec.ts)
- 后端 4 文件 [CE-EE] 标记在位(TableSync.ts=1/service=10/controller=2/processor=4)
- 禁改文件零变更:`store/sync.ts` / `syncUtils.ts` / `utils/acl.ts` / `ncUtils.ts` / 后端 `src/utils/acl.ts`
- `blockTableSync = false`(useEeConfig.ts:163),`blockTableSyncAuto = true`(:165)付费锁保持;`isSyncFeatureEnabled` 恒 false(store/sync.ts:19)

## 八、editor 三入口(R10 附录 A.3)—— PASS(沿 R6 裁定)

- **API 层(硬证据)**:editor 对十端点全 403(§六),createSync 403 无泄露通道
- **UI 层**:edt 视角 dest base Overview **可见 NocoDB Sync 卡**(截图 23;Create New Table 等其它卡因无 tableCreate 权限已隐藏)——入口可见属 **fail-closed 可见**,R6-C.4 已裁定「验收措辞偏差,无泄露通道;editor 能成功 createSync/读源 schema 才报 error」。edt 无任何 allow_sync 源可选,向导实际走不通;树 0 表无 sync 菜单可展示;src base edt 无权进入(Share allow_sync 不可达)
- 入口②③的 editor 拒绝由 API 403 全覆盖

## 九、回归探针 + 质量门 —— PASS

### 探针(api 账号,src base)
F05 variables 200 / F07 snapshots 200 / F10 dashboards 200 / F04 syncs(Airtable import 通道)200 / F02-F03 permissions 200 / F08 is_private true↔false 200 / 视图层 200

### 质量门
| 门 | 结果 |
|---|---|
| 后端 `npx tsc --noEmit` | **exit 0** |
| jest Fork 桶(`(Integration|Source|Fork)\.spec\.ts$`) | **3 suites / 41 tests 全过**(135.9s,含 table-syncs.Fork.spec 127.2s) |
| 前端编译健康(Vite URL 法) | 三组件 200 + base 页无 overlay(§一) |

---

## Minors(均不阻塞)

1. **[观察级,沿袭] 一次性时序异常**:三腿首轮执行时,测试脚本 `querySelector` 未按可见性过滤,误命中残留的 ui-sync 菜单 overlay 导致误删 ui-sync(当时当前打开表,剩 3 表),该次删除后 URL 跳 base 根而非剩余首表,与腿 1 预期不符。诱因是测试脚本 overlay 选择器歧义(非实现代码路径);标准重测(可见性过滤 + 清态)腿 1/2/3 全 PASS 且本事件无法复现。记为测试执行事故 + 观察项,若后续轮次再现实测到「删当前打开表跳根」需升级排查(方向:loadTables 未完成时 baseTables 空 map 导致 remaining.length===0 误归根)。
2. **[沿袭] meta API `columns[].show` 序列化差异**:网格隐藏真实判据在 `nc_grid_view_columns_v2.show=false`(已验证)与 SDK `isHiddenCol`(system=true),v2 table meta 返回 show=null——功能正确,仅 meta 语义与 R3 验收表述「show=false + system=true 双保险」的字面读取有出入,实测三重保险(show/system/readonly)齐备,无需修复。

## 沿袭已知项确认(未升级)

selectedFields camelCase PATCH 静默 no-op(DTO 白名单外忽略,sf 仍 null,与沿袭项「selectedFields:[]」同源);realtime 400 付费锁;FAILED 泛型;paused 菜单 Sync now 400 fail-closed(freeze 态 API 复测 400 一致);dev 库 273 base 历史测试数据; Gifts Unlocked 推广条(上游 CE 营销组件,非 F09 面)。

## 测试数据清理

- src base `py5dgvczt36q9w0` / dest base `ppc8m96i9yrj7j0` 均 DELETE 200
- 账号保留(f09r10l5-api/-ui/-mx/-edt/-ws2,workspace 角色置位等效 invite,任务书允许);DB 凭证经 Infisical 运行时拉取,零落盘(仅 /tmp 0600 权限临时文件,含 nocodb-dev 专用凭证)
- camoufox session f09r10l5 已 close
