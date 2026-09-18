# R11 F09 lane5(UI 验证重点路)报告

**结论:PASS(0 error + 0 minor)** — F09 P1 连击 3/3(R9/R10/R11),本轮无新发现。

- 审查基线:HEAD 71dd2692b1(代码面同 5bea0c3943,git diff 5bea0c3943..HEAD -- packages/ 为空,实测核验)
- 账号:`f09r11l5-*` 前缀,API(owner/矩阵)与 UI(ui 账号)分离;camoufox session `f09r11l5`
- 测试 base 全部删除(7 base 软删进 trash = 平台统一语义;孤儿 sync 登记行 1 条已清;DB 复核零活跃残留)

---

## 1. 静态审查(R3 清单第 1 项站位)

- 保护文件零改动:`git log 71896a841f^..HEAD -- packages/nc-gui/store/sync.ts packages/nc-gui/utils/syncUtils.ts packages/nc-gui/utils/acl.ts packages/nc-gui/utils/ncUtils.ts` 输出为空(整个 F09 fork 期,含上游历史提交区分核验)
- `isSyncFeatureEnabled = ref(false)` 在位(store/sync.ts:19,恒 false)
- table-syncs.controller.ts 头部 `[CE-EE] F09` 标记在位;assertSourceReadAccess 三路判定(R5 版)在位(service L91-141,实测行为见 §3)
- F09 commit 链核对:71896a841f → ef942b141d/0f16d3cf40/c051bfa3db → 551694ecbe/798e860dd1 → f81e24a4f4/dd46a3eb1d → aabe3587fe → 5a11c4ab86 → 9c4db33fe1 → 5e3d736b2a,无未登记的 packages/ 变更

## 2. 引擎 e2e(API 实测,nocodb-dev,owner 账号)

| 验证点 | 结果 |
|---|---|
| full-create(delete 策略) | active + last_synced_at;镜像 3 行 Title 集合 row1,row2,row3;RemoteId 已填;mirror 表 synced=true |
| resync upsert(源 +row4) | 200 → 镜像 4 行 |
| delete 策略(源删 row4→resync) | 镜像回 3 行 |
| mark_deleted 策略 | 源删 row5 → resync → 镜像保留 row5 且 **RemoteDeleted=true**(独立三建复核,首轮脚本 resync 调用参数错位导致的假阴性已排除) |
| freeze | status=paused;paused 下 resync **400** |
| resume | status=active |
| realtime 触发 | createSync **400**(付费锁保持) |
| deleteSync | 200 → GET sync **404** + 镜像表从 base 移除(trash 语义) |

## 3. 权限矩阵

### E1 六格(显式 base no-access 调用者,dest-creator 提权经 API invite)

| 格 | 结果 |
|---|---|
| 非私有+no-access+ws 可读 | source-schema **404**;平台 GET base 403(两路皆拒) |
| 非私有+no-access+ws no-access | **404** |
| 私有+no-access+ws 可读 | **404**;平台 GET base 404 |
| 私有+no-access+ws no-access | **404** |
| createSync 数据面(非私有源) | **404** + dest 零镜像表落 |

### R5 象限(dest=matrix-dest,调用者均经 API invite 为 dest-creator)

非私有+零 base 行+ws-creator **200**;非私有+显式 editor+ws no-access **200**;非私有+零关系+ws no-access **404**;非私有+inherit+ws-creator **200**;私有+零 base 行+ws 可读 **404**;私有+inherit+ws-creator **404** —— 6/6。

### ACL 十端点 + editor + 匿名

- owner:list/get/source-schema/create/update(active 后)/resync/freeze/resume 全 **200**;resolve-link **501**(P1 占位,沿袭)
- editor(dest base editor,API invite):十端点全 **403**(含 list/get/source-schema/create/update/delete/resync/freeze/resume/resolve-link)
- 匿名:list/source-schema **401**
- 零关系 ws 用户对他人 base:list/create **403**(fail-closed,PASS)
- updateSync selected_fields 变更:**400**(P2 沿袭拒收)

方法学执行:角色变更经 API PATCH(base 级全 API);v2 records 单行 DELETE 用 body 式(`DELETE /records -d {"Id":N}`);syncing 互斥窗口等 active 后再操作(首次 400 为测试时序问题,非缺陷)。

## 4. 守卫链 + 系统列

- synced 表写路径:insert **400** / update **400** / delete 行 **422**(上游语义,沿袭)/ tableDelete **404** —— 全拒
- 系统列双保险:v2 meta `RemoteId`/`RemoteDeleted` readonly=true + system=true;DB GVC `show=false`(参数化查询实测:RemoteDeleted/RemoteId show=false,Title show=true)。`columns[].show=null` 为沿袭表述差,功能正确,不计
- Fields 面板暴露:editor UI 全程未见系统列(截图佐证)

## 5. UI 段(camoufox 活体,session f09r11l5)

### 5.1 编译健康先行门

- `/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` → **200**
- `/_nuxt/components/project/Action/CreateNewSync.vue` → **200**
- base 页全程无 vite-error-overlay(最终态复测 false/false/title-ok)

### 5.2 创建流(向导 + 树刷新)

- 三步按钮全在 body 渲染且可用:step0 Next(disabled→选完 enabled)、step1 Back/Next(**Back 往返实测**)、step2 Back/Create sync
- **可搜索选择器**:base 下拉输入 "ui-src" → 过滤命中 2 项;全名 → 精确 1 项;table 下拉 "ui_src" → 命中(NcSelect show-search,按 label 匹配)
- 创建后**不刷新页面**:树即时出现 synced 表(闪电图标)+ 第二个 sync 创建后再现(ui_src_1);toast 三采样(t+1s/3s/6s)全零 —— 无成功/错误 toast 并存
- Overview「NocoDB Sync」卡(入口1)对 creator 可见

### 5.3 删除流三腿 + 判别对照(camoufox 活体,全不刷新页面)

| 腿 | 操作 | 结果 |
|---|---|---|
| 腿3 非当前表 | 打开 tbl_keep,删 synced 表 ui_src | **URL 不变**(停留 tbl_keep)+ 树即时移除,剩 2 表 |
| 腿1 当前表 | 打开 ui_src_1,Delete sync 确认 | **自动跳剩余首表 tbl_keep**(URL 与主区一致,无空白网格)+ 树即时移除 |
| 腿2/对照 0 表 | DlgTableDelete 删普通表 tbl_keep(当前打开) | 删至 0 表 → **URL 归一 base 根** `/nc/psa02zrn0ffdnxq`,Overview 面板显示 |

判别对照:普通表菜单 = Rename/Change icon/Duplicate/Description/Permissions/**Delete table**(DlgTableDelete,确认弹窗「Delete Table」),**无 sync 项**;synced 表菜单 = 通用项 + **Sync now/Pause sync/Delete sync**(SyncMenuOptions,确认弹窗「Delete sync」)。F09 删除流后清理与 DlgTableDelete 同款(R6 对齐点),0 表归根行为一致。

### 5.4 树菜单新鲜度三态翻转(全程无页面刷新)

active(Sync now + Pause sync)→ Pause 后重开菜单 = **Resume sync** → Resume 后重开 = **Pause sync** → Sync now 后 t+2s/t+7s 重开 = active(无 Syncing 粘滞)。菜单每次打开重拉(open watch 生效,M2 修复保持)。

### 5.5 allow_sync UI(Share 弹窗)

- 公开视图后「Allow sync」区块渲染,**无 paywall badge**;开关开启后 switch [checked]
- DB 持久化复核:该 view `allow_sync=true`

### 5.6 editor 三入口不可见(bedit 账号,base editor,活体)

1. Overview/Data Actions「NocoDB Sync」卡:**不可见**
2. Share 弹窗「Allow sync」区块:**不可见**
3. 树节点菜单 sync 项(Sync now/Pause/Resume/Delete sync):**无**(menuitem 零命中,截图佐证)

API 侧 editor 十端点 403 已在 §3 覆盖。

## 6. 质量门

| 门 | 结果 |
|---|---|
| 后端 tsc(`npx tsc --noEmit`) | **exit 0** |
| jest Fork 桶(testRegex Integration|Source|Fork) | **41/41 passed,3 suites**,104.3s,exit 0(日志含单测故意注入的 processor 失败输出,非错误) |
| Vite URL 编译检查 | 两组件 **200**(§5.1) |

## 7. 环境与方法备注(不计 error/minor)

1. **signup 默认角色**:新 signup 用户 org-level-viewer + Default Workspace `workspace-level-no-access`,无 baseCreate 权限。owner/UI 账号经 SQL 一次性置位(org-level-creator + workspace-level-creator,非 super,等效 invite 允许项);矩阵账号 ws 角色 SQL 一次性置位,base 级角色全经 API。ws 角色 API PATCH 403(见 2),切换用 SQL + 实测生效(workspace_user metaGet2 直查无缓存,置位后立即生效复验过)。
2. **上游 ACL 怪癖观察(范围外)**:utils/acl.ts 中 workspace-level-**viewer** include `workspaceUserList`+`workspaceInvite`,而 creator 的 include 无此二项 → creator 调 workspace invite/list 403(owner exclude={} 全许)。上游 CE 语义疑点,非 F09 引入(acl.ts 零改动),方向 fail-closed,留 upstream 观察。
3. **camoufox 会话两次意外断开**(登录态丢失):重连重登后继续;DlgTableDelete 首次确认点击随 tab 断开未落库,DB 复核(tbl_keep deleted=null)后重做 PASS —— 非被测实现问题,残留点击无半程写入。
4. 测试脚本缺陷自纠(不涉被测):api 函数 `$4` 参数错位把 `-o /dev/null` 吞成 body(E4 resync 假阴性,已独立三建复核 mark_deleted 真实 PASS);chkin glob 模式误判(403/404 实为预期拒码)。
5. 凭证零落 git:DB 凭证运行时经 Infisical 拉取(KDL project,库名硬编码 **nocodb-dev**),临时 env 落 /tmp 600 权限。

## 8. 沿袭已知项复核(未升级)

selectedFields:[] 空数组(本轮 updateSync 拒收 400 正常)、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限(P2 灰区)、403/404 vs 平台(fail-closed)、FAILED 详情泛型、resolve-link 501、realtime 400(付费锁)、editor 删镜像行 422、paused 菜单 Sync now 400 fail-closed、深链树骨架(框架级)、source-schema 对无 allow_sync 视图 200(create 侧强制)、columns[].show=null 表述差 —— 全部维持沿袭态,无升级。
