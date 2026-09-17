# F09 R5 lane3-b 审查报告（Table Sync P1，审查对象 f81e24a4f4）

> 落盘说明：`.work/ee-ce/r5-f09-lane3.md` 已被先前 lane3 填写（本路禁读他路报告，未读内容），故本报告落 `r5-f09-lane3b.md`（派遣账号前缀即 `f09r5l3b-b`）。
> 审查员：R5 独立第 3 路 b（ZCode subagent，隔离，未读他路报告）。
> 审查对象：HEAD = f81e24a4f4（R5 前置修复批）；:8080 运行构建核验通过（进程 05:31:27 启动，`~/.nocodb-run` dist 与仓内 dist md5 一致 = 65ddfb78982743a906b98cdbad68a354，含该修复）。
> 方法：静态审查 + API 实测（:8080，非 super 账号）+ camoufox session `f09r5l3b` UI 实测。账号前缀 `f09r5l3b-*`；测试 bases 已清理；全程未触碰 dev-backend*.sh / pkill / 重启后端。

## 结论：**1 error（必修）+ 2 minor observation**

- **E1（error，ACL 绕过）**：`assertSourceReadAccess` non-private 分支放行「显式 base `no-access` + workspace 高角色」用户——平台层对同一用户同一 base 明确 403。实测泄露完整源 schema，且 createSync+resync 通道可持续镜像被屏蔽数据。源码级 + API 实测双确认。
- 除 E1 外，8 项清单全过（含 R4 增量附录 3 项回归；R2 已知 minor 未升级）。

---

## E1 详证（必修）

**源码**（`packages/nocodb/src/services/table-syncs.service.ts:108-127`）：

```ts
const hasExplicitBaseRole =
  baseRole !== '' && baseRole !== 'no_access' &&
  baseRole !== ProjectRoles.NO_ACCESS && baseRole !== 'inherit';
...
} else if (!hasExplicitBaseRole && !hasWsRead) {   // :124
  NcError.baseNotFound(sourceBaseId);
}
```

non-private 放行条件等价于 `hasExplicitBaseRole || hasWsRead`。base 角色显式等于 `no-access`（`ProjectRoles.NO_ACCESS`，sdk enums.ts:40）时 `hasExplicitBaseRole=false`，ws 角色非 no-access 即**放行**。

**平台判定**（`BaseUser.ts:563-631` base list SQL）：path 2 fall-through 前提是 base role `NULL OR INHERIT`（显式 whereNull/=INHERIT 条款），显式 `no-access` 两路皆闭（path 1 排除 no-access；path 2 只接受 null/inherit）→ 平台**拒绝**。实现把「显式 no-access」误作「无显式角色」fall-through。

**API 实测**（三步交叉；ws 提权经 workspace invite/PATCH API 完成，测毕已还原 no-access）：

| 场景 | 结果 |
|---|---|
| `f09r5l3b-bnoaccess`：src-open 显式 `no-access` + `workspace-level-creator` + dest creator → POST source-schema | **200**，响应体泄露源 base title / table title / views / columns 全量 |
| 同一用户同一时刻 → 平台层 `GET /api/v2/meta/bases/:srcOpen` | **403** `Forbidden - You do not have permission to view base details with the roles: .` |
| 同一用户 → 平台层 `GET /api/v2/tables/:srcTbl/records` | **403** |
| private + 显式 no-access + ws creator → source-schema | 404 ✓（private 分支正确；缺陷仅 non-private） |
| 交叉 `f09r5l3b-zero`：零 base 关系 + ws creator + non-private → source-schema | 200 ✓（CE 继承正向正常，证明缺陷仅在显式 no-access 未短路） |

**影响**：被显式设为 `no-access` 屏蔽的用户（如移出协作但保留 workspace 身份者）直读 base 被平台 403，却可经 F09 source-schema / createSync+resync 读走并持续镜像被屏蔽数据。

**修复方向**（单点小改）：显式 no-access 须短路拒绝——

```ts
const explicitNoAccess =
  baseRole === 'no_access' || baseRole === ProjectRoles.NO_ACCESS;
// non-private 放行 iff hasExplicitBaseRole || (!explicitNoAccess && hasWsRead)
```

修复后回归矩阵：零关系 ws-creator 200、inherit ws-creator 200、显式 no-access 404、private 四象限不变。

---

## 通过项（8 清单 + R4 增量）

**1. diff 审查 ✓**
- F09 链 7 commits（71896a841f → f81e24a4f4）文件集与 impl-report 一致（后端 model/service/controller/processor + jobs 注册 3 文件 + nc-gui 7 文件）。
- [CE-EE] F09 标记计数：TableSync.ts=1、service=10、controller=2、processor=4、jobs-map.service=3、jobs.module=1。
- 禁改文件零 F09 改动（git log 验证）：`nc-gui/store/sync.ts`、`utils/syncUtils.ts`、`utils/acl.ts`、`utils/ncUtils.ts`。
- `isSyncFeatureEnabled = ref(false)`（store/sync.ts:19）恒 false。
- R4 增量-2：jobs-map [CE-EE] 标记在位（≥3 处）。
- R4 增量-3：console.debug 零残留（4 个后端 F09 文件 grep 零命中；统计日志走 Nest Logger）。

**2. 引擎 ✓**（table-sync.processor.ts）
- RemoteId 键控 upsert：e2e 实测新增镜像、已存在行刷新（row1 Qty=99）、消失行按策略处理。
- 分页双侧 500/页 + seenRemoteIds 去重。
- 白名单通道（allowSystemColumn + skip_hooks/skipPermissionCheck/skipAttachmentOwnershipCheck）仅 processor 内部三个写点；HTTP 层无通道（直写镜像全 4xx 实测）。
- 失败落账 status=error+last_error、sync_job_id 清空、swallow 不重投（:71-81）；jest 有对应用例（运行日志可见 "run failed: db exploded"）。
- paused 跳过（:53-56）。

**3. 服务 ✓**
- realtime 400（API 实测）；blockTableSyncAuto/blockCustomSync 保持 true（付费锁）。
- allow_sync 强制：关 → createSync 400（PATCH=false → GET 确认 → 400 → 还原）。
- 镜像列过滤、保留名守卫（title/column_name 双查）、system:true 后置补丁（meta 层实测 system=true）、show=false 补丁（GVC 层实测）、R2 缓存失效修复在位。
- R4 增量-1：is_private 分流源码验证 + 8 象限 API 矩阵全对（见 §4）。

**4. ACL 矩阵 ✓**（API 实测，非 super）
- is_private 判定矩阵 8/8（操作者均 dest creator）：

| 源关系 | non-private | private |
|---|---|---|
| 显式 editor | 200 ✓ | 200 ✓ |
| 显式 inherit | 404 ✓ | 404 ✓ |
| 显式 no-access（ws no-access） | 404 ✓ | 404 ✓ |
| 零关系 | 404 ✓ | 404 ✓ |

- owner/creator 十端点全 200；resolve-link 501 ✓；realtime create 400 ✓。
- editor（受邀）10/10 端点 403；viewer 抽查 403；匿名 401×3；creator delete 200 → GET 404。
- 说明：ws-creator 象限原不可测（无 super/无 psql），本轮经 ws invite API 实测补齐——继承正向 200 ✓；显式 no-access 象限即 E1。

**5. 引擎 e2e ✓**
- full-create：行数一致，RemoteId/Title/Qty 逐行对照一致。
- resync upsert：源 +rowX(Qty=777) 镜像进；row1 Qty=99 刷新进。
- on_delete 双策略：mark_deleted → 源删行镜像保留 RemoteDeleted=true；切回 delete → resync 移除。
- freeze → resync 400 → paused；resume → active。
- deleteSync → GET 404 + 镜像表移除（trash）。
- selected_fields 白名单：镜像 readonly 列集 = RemoteDeleted,RemoteId,Title，数据仅 Title。
- updateSync 拒收 selected_fields 变更（400）。

**6. 守卫链 + 系统列 ✓**
- editor insert 镜像 400；creator 直写镜像 400；creator 建 form view 于镜像 → 422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`（上游 forms.service 错误码，守卫生效）；删镜像表 creator 400 / editor 403。
- UI 佐证：synced 表视图菜单 Form 项 disabled。
- RemoteId/RemoteDeleted：system=true + readonly=true（meta 层）+ GVC show=false（Title/Qty show=true）——show=false + system=true 双保险在位（R2 E2 回归通过）。

**7. UI 段 ✓**（camoufox --session f09r5l3b，截图 /tmp/f09r5l3b-ui1…ui11）
- 向导三步按钮全部 body 渲染可用：step1 Browse + base/table 下拉（排除自身 base）+ Next（未选源 disabled 合理）；step2 Fields radio + Back/Next；step3 标题 + Manually 锁定 + 删除策略 radio + Back/Create sync。实点 Back→Next→Create sync → 后端 sync active。
- 管理面板全流程实点：Sync now（last_synced_at 22:07:49→22:13:36）、Pause（API paused、菜单变 Resume sync）、Resume（API active）、Delete sync → 确认弹窗 Cancel/Delete 双按钮在 body（R2 E1 回归）→ 确认删除。
- tooltip 徽标："Synced table / Last synced …"。
- editor 三入口不可见：Sync 卡片 0；表节点菜单按钮 0 尺寸不可点；Share 弹窗打不开。
- console error + Nuxt overlay 双零（collector 历经向导开关等操作 errs=[]）。

**8. 回归 + 质量门 ✓**
- `npx tsc --noEmit` exit 0；jest Fork 桶 **41/41**（3 suites）。
- F04 legacy syncSource list 200；F05 variables 200；F07 snapshots 200；F08 is_private 重度实测 ✓；F10 dashboards 200；F02/F03 permissions 端点存活（400 拒绝无崩溃；该文件无 F09 改动）。

## Minor observations（不计 error）

- **m1**：Create sync / Delete sync 成功后树不即时刷新（需 reload）——API 即时正确，前端刷新缺口。
- **m2**：引擎 update 分支仅 markDeleted 策略清 RemoteDeleted（processor.ts:213-215）——策略切回 delete 后源行回归会残留 stale 标记（隐藏系统列，数据正确）；另刚 resync 完 tooltip 短暂 "Syncing"（前端缓存滞后）。
- **m3（沿袭未升级）**：selectedFields:[] 建零数据列镜像表；createSync 非原子孤儿表——R2 已知。

## 环境留痕

- 测试 bases 3 个已删（200×3）；账号 `f09r5l3b-{owner,beditor,beditor2,bviewer,binherit,bnoaccess,zero}@lan3.test` 保留（dev 库惯例）。
- 临时 ws 提权（bnoaccess/zero → workspace-level-creator）已还原 no-access（200×2）。
- 脚本 /tmp/f09r5l3b-{setup,matrix,acl,e2e,e2e2,e2e3}.sh；截图 /tmp/f09r5l3b-ui1…ui11.png。
- 教训：NocoDB 每次 signin 轮转 token_version 使同账号旧 token 全失效——多路并发审查期反复 signin 互踢（本路 UI 会话两次被踢即此因）；后续 lane 每账号 signin 一次缓存复用。
