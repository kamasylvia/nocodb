# r5-f07-lane3 — F07 Snapshots 第 5 轮会审报告（lane3：int 抽验 + rev 后端终审）

## rev（后端终审）

### R4 修复逐项终核

1. **unified deriveStatus 重推导**（`packages/nocodb/src/services/base-snapshots.service.ts:220-249`）：所有状态（含 terminal）均经 `getCopyBaseRow` cache-free 重探测；`!copyRow && status==='error'` 返回 null 不再重复写；超时判定 probe-first（仅 `copyRow.status===ProjectStatus.JOB` 时才看 15min 超时，慢 base 不误标）。误标可自愈：copy 完成后下次推导由 `completed` 分支覆盖旧 `error`。核过 SDK `ProjectStatus.JOB='job'`（`nocodb-sdk/src/lib/globals.ts:133`）与 duplicate.processor 成功路径 `baseUpdate(status:null)`（`duplicate.processor.ts:325-329`）、失败路径 `baseSoftDelete`——deriveStatus 三分支与真实流转闭环一致。
2. **getCopyBaseRow RootScopes.WORKSPACE**（service:255-270）：对照 `contextCondition`（`src/meta/meta.service.ts:266-291`）——`base_id==='workspace'` 时仅加 `fk_workspace_id` 条件并 return，`metaGet2` 主体（meta.service:710-711）再加 `id=snapshotBaseId`；最终 SQL `WHERE fk_workspace_id=? AND id=?` 语义正确。RootScopeTables 检查仅 `workspace_id===base_id` 分支触发，此处不受 PROJECT 不在 WORKSPACE 表清单影响。
3. **ensureCopyExists**（service:121-136）：restore 前校验副本存在，缺失则落 `error` + 400；位于 `derived==='completed'` 判定之后属冗余防御，无害。
4. **cleanupByBaseIdWithCopies**（`src/models/BaseSnapshot.ts:182-208`）：Base.softDelete（`src/models/Base.ts:457`）与 Base.delete（`Base.ts:707`）双挂点正确；动态 import 防环（静态方向仅 Base.ts→BaseSnapshot.ts 单向，无静态环）；副本软删 try/catch 容错、登记行必删；嵌套快照链单向无递归环。
5. **删快照守卫**（service:196-217）：副本已消失仍删登记行（先 probe 再条件软删），不 500。实测 DELETE 200 + DB 行消失。
6. **title 校验**（service:33-39）：非 string→400、>512→400，实测通过；空/空白 title 落默认 `Snapshot <ts>` 合理。

### 全文再扫

- BaseSnapshot model 缓存键全链一致：insert 先物化再 appendToList（R1 修复），get/set/update/delete、deleteByBaseId 的 deepDel key `snapshot:<baseId>:list` 与 `CacheMgr.getList` key 构造（`src/cache/CacheMgr.ts:276-279`）+ `NocoCache.deepDel` 前缀拼接（`NocoCache.ts:184-186`）匹配。
- `src/helpers/dataHelpers.ts` base undefined 守卫：`NcError` 已 import（L19），tsc 过。
- ACL：后端 `permissionScopes.base`（`src/utils/acl.ts:273-278`）与前端 CREATOR include（`packages/nc-gui/lib/acl.ts:143-147`）各注册 4 权限，与 F05 同块同模式；UI gate `blockSnapshots=false`（`useEeConfig.ts`）+ `BaseSettingsMenu.vue` / `project/View.vue` 改判 `baseSnapshotList` 权限，无 `isEeUI` 全局翻转。
- `noco.module.ts` controller/service 注册齐；`models/index.ts` 导出齐。

### 实跑

- `npx tsc --noEmit`：exit 0，0 error。
- `npx jest baseVariableValidators --runInBand --forceExit`：12/12 passed。

### 攻击性找茬

**无**（无 API 可达链的 error 级问题）。备注（均非 error，不要求修）：createSnapshot mutex check-then-insert 竞态已在代码注释文档化为 residual risk；listSnapshots 每快照 1 次 DB probe 属 N+1 性能 note；`nuxt.config.ts` `allowedHosts:true` 仅 dev 配置无生产链。

rev 结论：**PASS**

## int（集成抽验）

环境：dev server :8080（nocodb-dev），新测试账号 lane3f07@eetest.local（SQL 提权 workspace-level-creator），全新 base 全生命周期 1 轮 + 删源 base 清理核验（pg8000 直查 nocodb-dev，凭证 Infisical KDL DB_* 运行时注入，未触生产库）。

脚本：`.work/ee-ce/int-lane3-f07.sh`（本轮 24/25，唯一 FAIL 为脚本断言写法：PG bool 经 Python 打印 `True` 与期望串 `true` 大小写不符；直查 DB 确认副本 `pt354xl3znqu71o` deleted=true，产品行为正确）。

实测项（全部通过）：

1. 生命周期：create snapshot（默认 title `Snapshot 2026-09-12T15-39-21` 格式正确、初始 processing）→ poll 至 completed → restore 返回新 base_id（`pmmifhfomgtfq9e`，存活且 cleanup 不误伤）→ delete snapshot 200。
2. 第二快照（自定义 title `lane3-keep`）独立 completed；DB 快照行数=2。
3. 删快照 ×2：API 200；DB 登记行消失、副本 base `deleted=true`（快照1、快照2 副本均验证）。
4. 删源 base 清理核验：DELETE base 200 → `nc_snapshots` 中该 base_id 行全清（0 残留）；处理中的快照3副本（`pdyw4005jlii3i9`）也被 soft-delete；源 base deleted=true；restored base 不受 cleanup 影响（断言时 deleted=false，随后脚本主动清理）。
5. 边界：title 非 string→400；title 513 字符→400；restore 不存在 snapshot→404；未认证 create→401。
6. dev 库残留 `nc_snapshots` 15 行分布核验：8 个源 base 全部存活（历史轮测试活跃数据），孤儿行 0，非缺陷。

int 结论：**PASS**

## 总裁决

int PASS + rev PASS，0 error。F07 第 5 轮 lane3 通过。
