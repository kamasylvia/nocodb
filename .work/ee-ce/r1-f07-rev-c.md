# r1-f07-rev-c.md — F07 交叉面复审(第 5 路,独立)

> 复审范围:安全/语义、一致性、测试基建、文档、commit 清单。证据:git diff 全量 + 源码读码 + tsc/jest 实跑 + backend.log。
> 隔离:未读任何 r*.md;只读 TASK.md / 仓根 AGENTS.md / 源码 / GOAL-STATE / TODO。

## 裁决

**issues(5 error + 5 low/流程)**

### error(必修)

1. `packages/nocodb/src/services/base-snapshots.service.ts:160:deleteSnapshot`:副本 base 已不存在/已软删时 `Base.softDelete` 内 `base.fk_workspace_id`(models/Base.ts:444)TypeError → 500,快照行永远删不掉(僵尸行)。可达链:job 失败 → duplicate.processor.ts:341 catch 里 baseSoftDelete 已把副本软删 → deriveStatus 判 'error' → UI delete 按钮(status 不 disabled)可删该快照 → softDelete 炸。实测证据:backend.log 11:05:00 两次 `GlobalExceptionFilter ERROR: Cannot read properties of undefined (reading 'fk_workspace_id')` at Base.softDelete ← deleteSnapshot(service:160)。建议:softDelete 前先 `Base.get` 副本,拿不到则跳过 softDelete 直接删 nc_snapshots 行(或对 softDelete 段 try/catch 容忍)。

2. `packages/nocodb/src/services/base-snapshots.service.ts:37:createSnapshot`:`body.title` 无类型守卫,title 非 string(对象/数字)→ `.trim is not a function` TypeError → 500。实测证据:backend.log 11:04:53 两次 `TypeError: _body_title.trim is not a function`。与 F05 R4 判例同型(description 对象 → 500 判 error)。建议:`typeof body?.title === 'string'` 守卫,非 string 忽略走默认标题或 400。

3. `packages/nocodb/src/models/BaseSnapshot.ts:103:insert`:缓存写入顺序反了——先 `appendToList`(子键尚未 set)后 `get`。每次创建快照必打 `CacheMgr ERROR: appendToList: value is empty` + fallback 把 scope list 缓存整键 deepDel(附 `getParents: parentKeys not found` ERROR),delete 时同报。违反验收清单「无 console.error 残留」。功能未坏(fallback 自愈=下次 list 走 DB),但 ERROR 级日志每次必现。实测证据:backend.log 10:46:56 起 8+ 处。建议:照上游惯例(Extension.insert:先 `this.get()` 把单键 set 进缓存,再 appendToList)调序。

4. `packages/nocodb/src/models/BaseSnapshot.ts:152:deleteByBaseId`:死代码(全仓 0 调用点)。Base.softDelete(models/Base.ts:453)与 Base.delete(:696)只挂 Extension/BaseVariable 的 deleteByBaseId,F07 未挂。后果:删除原始 base → nc_snapshots 行孤儿残留 + 快照副本 base(完整数据拷贝)永久残留于 workspace base 列表。与 F05 R1 同型判例(deleteByBaseId 从未被调 → 判 error 修复)。另 service:156 注释「softDelete also runs our deleteByBaseId hook」有误导——那讲的是 F05 的 BaseVariable hook,非 BaseSnapshot。建议:Base.softDelete 与 Base.delete 补挂 `BaseSnapshot.deleteByBaseId`(删快照行;副本 base 若仍 live 则 softDelete)。

5. `packages/nc-gui/components/dashboard/settings/base/Snapshots.vue`(restoreSnapshot):`navigateTo(`/${restoredBaseId}`)` 单段 URL 与路由树不符。base dashboard 路由 = `/nc/:baseId`(store/base.ts:281 baseUrl=`/nc/${id}`;TreeView/ProjectNode.vue:398 同形态;admin/InstanceBases.vue:73-75 双段 `/${ws}/${base}`)。`/base_xxx` 会落 `pages/index/[typeOrId]` 层 → restore 成功后跳错页/404。f07-e2e 为 API 测试覆盖不到此 UI 路径。建议:改 `/nc/${restoredBaseId}` 或用 `baseUrl({ id, type: 'database' })`。

### low / 流程(记录,可下轮修)

- `Snapshots.vue:createSnapshot` 轮询逻辑:break 条件 `some(s => s.status === 'completed')` 对已有 completed 快照的 base 恒真 → 新行可能一次都不刷新;且 3×1.5s=4.5s ≪ job 实际 10-25s,完成后无自动/手动刷新手段,新快照状态卡 processing 直到重进页面。建议按新 snapshot id 轮询 + 延长窗,或补刷新按钮。
- createSnapshot 无数量/频率上限:每快照=全 base 副本(存储放大),API 可循环创建(processing 门只挡并发)。fork 单机可接受,记录为观察;不与 EE limit 对标。
- backend.log JOB FAILED(建快照后删原 base,排队 duplicate job 必失败)= 上游 duplicate 同款既有行为,非 fork 引入,记录不修。
- `.work/TODO.md` F07 行未同步(仍「表已有,补 controller/service + UI」,未注「实现完成,R1 会审中」;F01/F05 均有行内状态注记,TODO 为状态唯一判据)→ 流程项。
- AGENTS.md 建议增补 F07 段(GOAL-STATE 有而 AGENTS.md 无):快照=异步完整副本 base(nc_snapshots 登记,副本 title 前缀 `Snapshot <ts> of <base>`,owner=发起者);restore=对副本再 duplicate 为 `<orig> (restored)` 新 base,不原地覆盖;delete=Base.softDelete 副本 + 删行(trash 残留可恢复=平台统一语义);状态由副本 status 派生(job→processing / live→completed / 副本消失→error);修复 #4 后 Base softDelete/delete 挂 BaseSnapshot.deleteByBaseId。

## 任务分项结论

- **安全(任务 1)**:副本 base 由 basesService.baseCreate 创建,owner=req.user,duplicateBase 不继承/复制协作者 → 仅 creator 可见,无跨用户暴露;副本出现在 creator 自己 base 列表=已记录的设计(GOAL-STATE),非权限问题。restore 仅 creator 可触发(@Acl baseSnapshotRestore,服务端 exclude 模型天然 creator+,与 F05 同机制;前端 View.vue 深链 + 菜单双门 baseSnapshotList)。删除快照=软删副本+删行,trash 中副本可被恢复(恢复后为无快照登记的普通 base)= 平台 trash 统一语义,判定可接受。restore 构造 snapshot-base context 调 duplicateBase,route ACL 先行,无提权面。**语义判定:合理;error#1/#4 属该语义下的实现缺陷。**
- **一致性(任务 2)**:[CE-EE] 标记覆盖 F07 全部新改段(models/index export 行与 lang 新键无标记=F05 既有惯例);`Api.ts` / `ncUtils.ts(isEeUI)` 未动(git status 无)✓;acl 双侧 4 op 名完全一致(baseSnapshotList/Create/Restore/Delete,server permissionScopes ↔ controller @Acl ↔ 前端 creator include)✓;controller v1+v2 双路径与 F05 base-variables.controller 同款 ✓。
- **测试基建(任务 3)**:tsc 0(实跑,无错误输出)✓;jest 26/26(实跑,2 suites:uniqueConstraintHelpers + baseVariableValidators)✓;backend.log 有 F07 ERROR(error#1/#2/#3 来源,非全为噪音)✗ 见 issues;f07-e2e.sh 读码:RUN_TS 时间戳命名 + trap cleanup,可重复跑,残留仅 trash 软删行(平台语义),幂等性 ✓。F07 无新增 jest/vitest spec(service 逻辑依赖 DB+job,无可提取纯函数)——记录,不强制。
- **文档(任务 4)**:AGENTS.md 无 F07 内容 → 增补项见 low 第 5 条。
- **commit 清单(任务 5)**:git status 13 件(3 新:model/service/controller + 10 改:Snapshots.vue/BaseSettingsMenu.vue/View.vue/useEeConfig/lib-acl/en/zh-Hans/models-index/noco.module/utils-acl)与任务给定清单逐一相符,无多余文件;diff 内容逐 hunk 核过,全部 F07 相关,无夹带 ✓。
