# F09 R5 lane1 报告(zcode 独立第 1 路;R5 修复批 f81e24a4f4 回归轮)

> 审查对象:HEAD = f81e24a4f4("F09 R5 — rewrite assertSourceReadAccess to mirror the platform predicate exactly")。
> 本轮性质:R5 第一轮五路收敛后主会话落了 R5 修复批 f81e24a4f4,本轮按 r4-f09-lane-prompt.md(R1-R5 同规格 + R4 增量附录)对该修复批做回归复审。(旧第一轮报告已备份 /tmp/f09r5l1b-prev-lane1-backup.md)
> 方法:静态 diff/model/service/processor 全读 + API 实测矩阵(非 super 账号)+ 引擎 e2e + camoufox(session f09r5l1b)+ tsc/jest。
> 账号:f09r5l1b-*(wsc=ws creator / ed=np-src editor / edd=np-dst editor / na=base no-access / na2=base no-access+ws creator / noacc=零关系 / vw=viewer);建库工具借用共享基建账号 f01e2e(仅 signin,数据对象全部 f09r5l1b- 前缀)。数据清理:全部测试 sync 已删,base 按惯例留存。

---

## 结论:**1 error**(R5 修复批未完全达成其自述目标,遗留一个泄露象限);3 minor;数条 observation。

---

## E1(error)— assertSourceReadAccess 对「base 显式 no-access + ws 有效角色 + 非私有源 base」象限放行,与平台谓词相悖,源 schema 读取 + createSync 全链泄露

- **位置**:`packages/nocodb/src/services/table-syncs.service.ts:107-127`(f81e24a4f4 重写后的 `assertSourceReadAccess`)
- **根因**:重写把判定写成
  ```
  hasExplicitBaseRole = baseRole ∉ {'', 'no_access', ProjectRoles.NO_ACCESS, 'inherit'}
  hasWsRead = wsRoles.some(r => r !== 'workspace-level-no-access')
  非私有: deny 仅当 (!hasExplicitBaseRole && !hasWsRead)
  ```
  即「无显式有效 base 角色 → 看 ws 角色」。但平台谓词(`BaseUser.ts:563-631` getProjectsList,workspaceId 分支)Path 2 的前提是 **base role IS NULL 或 INHERIT**——显式 `no-access` 行两个 Path 都不满足 → 平台 404/403。重写把「显式 no-access」与「无 base 行」合并进 `!hasExplicitBaseRole`,再用 ws 角色兜底放行,与平台 Path 2 的前提条件不一致。
- **实测**(全部账号对 dest base 有 creator 角色,排除 dest 侧 ACL 干扰;`platform` = GET base/tables/records 三端点):
  | 象限 | platform | tableSyncSourceSchema | 判定 |
  |---|---|---|---|
  | base-editor + ws-no-access(非私有) | 200/200/200 | 200 | ✓ |
  | base-no-access + ws-no-access | 403 | 404 | ✓(拒,语义等价) |
  | 零关系 + ws-no-access | 403 | 404 | ✓ |
  | 零关系 + ws-creator | 200/200/200 | 200 | ✓ |
  | **base-no-access + ws-creator(非私有)** | **403/403/403** | **200** | **✗ E1** |
  - 泄露深度:该账号(na2)随后 **createSync 成功**(`POST /table-syncs` 200,sync `tsscpzqm0t2q3wqkc`),引擎 full-create 跑完(status=active,last_synced_at 落账),源表 3 行 row1/row2/row3 全部落入镜像表(API 核对 `[.list[].Title]=row1,row2,row3`)。即:被平台显式拒之 base 门外的用户,可经 Table Sync 把该 base 数据**整表拉走**。
  - 修复方向:非私有分支需区分「base 行存在但显式 no-access」(→ 404)与「base 行不存在/inherit」(→ ws 继承判定)。即 `baseRole === '' || baseRole === 'inherit'` 才进入 hasWsRead 兜底;baseRole 为显式 no-access 时直接 deny(私有分支已正确,仅非私有分支需加一个分支)。
  - 注:f81e24a4f4 自述 "mirror the platform predicate exactly",commit message 列出的三个坏象限已修(E 象限 200 ✓、D 象限 404 ✓、私有+inherit 404 ✓),但引入/遗留了上述第四象限。
- **严重性**:error(数据面越权读取;R2 E1 同类,叠加 createSync 写通道)。

## M1(minor)— 向导 NcSelect `filterable` 缺 `:filter-option`,base/table 搜索只按 value(id) 匹配

- `packages/nc-gui/components/project/Action/CreateNewSync.vue:185-191 / 198-205`(base 与 table 两个 NcSelect)。
- 实测(dev 库 235 bases):下拉注入过滤词 `Getting`(label)→ 0 命中;注入 base id 前缀 `p206rwl` → 1 命中。用户按名字搜索必空,只能虚拟滚动 234 项。
- 仓内惯例是显式传 `:filter-option`(对照 `FieldSettingsAutocomplete.vue:241`、`EmailResponses.vue:192`)。可用性缺口,无安全问题。

## M2(minor)— 树节点同步菜单状态陈旧:Sync now 后重开菜单仍显示 Syncing,freeze/resume 项被隐藏

- `SyncMenuOptions.vue` 经 `useTableSync.ts:79 onMounted(load)` 只在组件挂载时拉一次;NcDropdown overlay 复用组件实例,重开菜单不重新 load。
- 实测:noacc(creator)Sync now → API 真值 active(last_synced_at 22:33:31),重开菜单仍显示 `Syncing` → `v-if status===Syncing` 使 freeze/resume 菜单项消失(`SyncMenuOptions.vue:62-90`),用户 Pause 通道被堵,直到刷新页面。数据层正确(freeze/resume API 均验证过),纯前端刷新缺口。

## M3(minor)— editor 对三个入口的可见性与「三入口不可见」验收不符(后端 ACL 兜底,无数据泄露)

- 入口一:editor 视角空 base 的 Data Actions **仍渲染 "NocoDB Sync" 卡**(`Overview.vue:134` gate 只有 `!blockTableSync`,无角色条件;截图 ui-20)。点击后向导可开,createSync 会被 ACL 403 拒(未放行数据)。
- 入口三:editor(源 base editor)Share 弹窗 **"Allow sync" 开关可见可点**(截图 ui-24);实测 PATCH allow_sync=false → **200**(平台 `viewUpdate` 对 editor 本就放行,acl include 模型)→ 与平台权限一致、无提权,但按 R3 清单「三入口不可见」验收未达成。开关语义与 API 权限一致,判 minor 交裁决。
- 入口二:editor 打开 synced 表节点菜单**无任何 SyncMenuOptions 项**(`useTableSync.load()` 拉列表 403 → sync=null → v-if 不渲染,fail-closed)✓。

---

## 八项清单核验(除 E1/M1-M3 外全部通过)

1. **diff 审查** ✓:71896a841f(16 文件)+ 修复批 0f16d3cf40/c051bfa3db/551694ecbe/798e860dd1/f81e24a4f4,源码 diff 恰 16 文件与 impl-report 一致;后端 7 文件全带 [CE-EE] 标记(jobs-map ×3 = R4 增量 2 ✓);`store/sync.ts` / `syncUtils.ts` / `acl.ts` / `ncUtils.ts` 零改动(git diff name-only 核对);`isSyncFeatureEnabled` 恒 false(store/sync.ts:19,消费者仅 F04 integration 休眠面);F09 前后端文件 `console.debug/log` 残留 = 0(R4 增量 3 ✓)。
2. **引擎审查** ✓:`table-sync.processor.ts` RemoteId 键控 upsert(extractPksValues→String→existingByRemoteId 对照,inserts/updates/stale 三分流);分页 500/页双向(dest existing + source);白名单通道(allowSystemColumn/skipPermissionCheck/skipAttachmentOwnershipCheck)仅 processor 内部,HTTP 不可达;paused 跳过;失败落 status=error+last_error、成功落 active+last_synced_at+sync_job_id 清空。
3. **服务审查**:E1 落在此项(见上)。其余 ✓:allow_sync 强制(resolveSourceView 两路 400)、镜像列过滤(isMirrorableSourceColumn:virtual/pk/ID/Order/CreatedTime/LastModifiedTime/CreatedBy/LastModifiedBy/Attachment/Deleted 全排)、保留名守卫(reservedNames 含 RemoteId/RemoteDeleted/Id/CreatedAt/UpdatedAt/nc_* 大小写双检)、realtime 400(`syncTrigger !== manual` 拒,实测 400)、system:true 后置补丁(metaUpdate + COLUMN:list deepDel)。
4. **ACL 矩阵** ✓(E1 象限除外):owner/creator 十端点 200(list/get/schema/create/update/delete/resync/freeze/resume;ResolveLink 501);dst-editor 十端点全 403(creator+/exclude 模型语义,实测 403×10);viewer 全 403;匿名 401。is_private 矩阵全对齐:私有+零关系(ws-creator/ws-no-access)404、私有+显式 editor 200、私有+显式 no-access 404、非私有全象限见 E1 表。
5. **引擎 e2e** ✓:full-create 3 行(RemoteId "1/2/3"、RemoteDeleted=false);源 +1 行 resync → 4 行(upsert);**delete 策略**(源删 row1 → resync → 镜像 3 行无 row1);**mark_deleted 策略**(源删 row4 → resync → row4 RemoteDeleted=true 其余 false);freeze→paused + paused resync 400 + resume→active;updateSync title 200 / selected_fields 400;realtime 创建 400(付费锁);deleteSync 200 → GET 404、镜像表进 trash、list 空。
6. **守卫链 + 系统列** ✓:synced 表 insert 400、删表 400;镜像列 Title/Qty readonly=true,RemoteId/RemoteDeleted system=true+readonly=true;网格**不渲染** RemoteId/RemoteDeleted(截图 ui-13);Fields 面板无系统列;树节点无 Delete table 项(`!table.synced`);New record 禁用态。
7. **UI 段**:向导三步 Back/Next/Create sync 按钮全部 body 渲染且可用(Back/Next 往返实测,截图 ui-05/09/10);创建全流程走通(浏览选 base/table → allow_sync 视图 → Retained 策略 → 创建,刷新后树出现 synced 表,截图 ui-12);树 tooltip "Synced table | Last synced …"(截图 ui-14);Sync now/Pause/Resume/Delete 全链实测(Pause→Resume→Delete 确认弹窗→树清空,截图 ui-15/17/18);console error + Nuxt overlay 双零(noacc 遍历 grid/菜单/Sync now,errs=[]、overlay=false)。缺口 = M1/M2/M3。
8. **回归 + 质量门** ✓:`npx tsc --noEmit` exit 0;jest Fork 桶 **41/41**(3 suites);探针 F02/F03/F04/F05/F07/F08/F10/AirtableImport 端点全部 `404 ERR_BASE_NOT_FOUND`(路由健康无回归);F08 私有语义本轮矩阵实测通过。

## Observations(不计 issue)

- createSync 非原子(镜像表先建、失败遗留孤儿表)与 selectedFields:[] 空数组——R2 已知 minor 沿袭,未升级,按任务书不重复报。
- 向导/树删除后 `loadTables()` 刷新不即时(需手动 reload),数据层正确。
- 平台对照注意点:base/tables/records 的拒绝码为 403 而 tableSync 侧为 404,拒绝语义等价(hide/forbid 混合),与历轮口径一致,不计。
- 测试基建:f01e2e 共享账号在五路并发下 token_version 互踢频繁(本轮 4 次掉线);建议后续轮各路用独立 ws-creator 账号(ws invitations 通道已验证可行)。

## 质量门

- tsc:exit 0
- jest:41/41(3 suites passed)
- 8080 全程未动(无重启/无 kill);camoufox session f09r5l1b 专属,已关闭

## 证据索引

- 矩阵/e2e 脚本与输出:/tmp/f09r5l1b-matrix.sh、/tmp/f09r5l1b-matrix-pv*.sh、/tmp/f09r5l1b-e2e*.sh、/tmp/f09r5l1b-acl10*.sh、/tmp/f09r5l1b-probe*.sh
- 截图:/tmp/f09r5l1b-ui-01..25*.png(向导三步/网格只读/树菜单/tooltip/editor 视角/确认弹窗)
- 关键 commit:f81e24a4f4(R5 修复批,本轮审查基线)
