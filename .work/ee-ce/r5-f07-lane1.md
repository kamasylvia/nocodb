# r5-f07-lane1 — F07 Manage Snapshots 第 5 轮收敛（int + rev）

账号：f07r5a@ce-ee.local 登录失败（Invalid credentials），回落 f01e2e@ce-ee.local（super，实测可用）。
环境窗口：测试中途后端 rspack autoRestart 重启 2 次（JWT secret 内存态失效 → 401），脚本加 re-login 韧性后全部重跑通过，非 fork 缺陷。

## int — PASS

T1 全生命周期（f07r5a_src，3 行数据）：
- create → 200，status=processing，登记 `snapzz6r5mpmpjmiwj` / 副本 `pls59wz9ehuoraw`
- 轮询 → completed（副本 base title `Snapshot 2026-09-12T15-32-29 of f07r5a_src`）
- 副本表/数据一致：f07r5a_tbl + rows {r1,r2} ✓
- restore → 200 `{base_id}`；新 base `f07r5a_src (restored)`；轮询 job 后 rows {x1,x2,x3}（T1b，src1b 3 行独立复测）✓
- delete snapshot → 200；副本 base GET → 404（软删）✓；list → [] ✓

T2 删源 base 级联（nc_snapshots/nc_bases_v2 pg8000 直查 nocodb-dev）：
- pre：1 行 completed + 副本 deleted=false
- API DELETE 源 base → 200
- post：该 base 的 nc_snapshots 行 = 0 ✓；副本 base deleted=true（cleanupByBaseIdWithCopies 连带软删）✓
- 追加验证：6 个测试残留 base API 级联删除后 nc_snapshots 全部 0 行 ✓

T3 副本不存在（DB 手动置副本 deleted=true）：
- GET 单条 → 派生 status=error ✓（unified deriveStatus 生效，persisted completed 被重推导）
- GET list → 同步派生 error ✓
- restore → 400 `Snapshot is not ready for restore (status: error)` ✓
- delete → 200，登记行清零 ✓（副本缺失不阻塞删除）

T4 边界/权限：
- title 非 string（123）→ 400 `Snapshot title must be a string` ✓
- title 513 字符 → 400 `exceeds 512 characters limit` ✓
- processing 互斥：create 后立即二次 create → 400 `Another snapshot is still being created...` ✓
- 跨 base 隔离：B base 路径访问 A 的 snapshot（GET/restore/DELETE）→ 全 404 `Snapshot not found` ✓
- editor（signup+invite 实建用户）四操作 list/create/restore/delete → 全 403 `with the roles: Editor` ✓

## rev — PASS

终审点逐项核过：
- unified deriveStatus 重推导：所有状态（含 terminal）cache-free 重探测；副本无 → error；job 态 probe-first/15min 超时兜底；completed↔error 瞬时误标自愈（base-snapshots.service.ts:220-249）
- getCopyBaseRow RootScopes.WORKSPACE：metaGet2(workspace_id, RootScopes.WORKSPACE, PROJECT, snapshotBaseId)，`deleted === true` 判无（:255-270）——R4 fix 在位
- ensureCopyExists：restore 在 derived===completed 后仍 cache-free 复查副本，缺失置 error + 400（:121-136）
- cleanupByBaseIdWithCopies：Base.delete(:453) 与硬删路径(:699) 双挂；dynamic import 防循环；副本软删逐行 try 吞错后仍清登记行；实测两轮验证
- /nc/ 跳转：Snapshots.vue restore 成功后 `navigateTo(/nc/${restoredBaseId})` ✓
- ACL 对齐：后端 utils/acl.ts permissionScopes 4 个 baseSnapshot*（creator+）；前端 lib/acl.ts 仅 CREATOR 块放行；editor 前后端一致拒绝（实测）
- gate：useEeConfig 仅 blockSnapshots→false，isEeUI 未动；View.vue / BaseSettingsMenu 门控一致
- dataHelpers.ts base undefined 守卫：NcError 已 import(:19)，404 干净

找洞（API 可达链）：无。
备注（非 error，代码内已声明文档化的 residual）：create mutex 为 check-then-insert 竞态（并发窗口可产生多副本，无损坏）——源码注释已声明，R1 起已知；processing 中删除 snapshot 允许（副本被软删，job 产物不产生 live 孤儿，符合 trash 语义），无用户可见错误路径。

## rev 实跑门

- `npx tsc --noEmit`：exit 0（0 错误）
- `npx jest baseVariableValidators --runInBand --forceExit`：12/12 passed

## 资源清理

- f07r5a_* base：live 0（全部经 API 软删，trash 语义保留 schema，平台一致行为）
- nc_snapshots 相关行：0
- 孤儿 schema：无（全部 base 行在档，无 hard-delete 遗留，无需 DROP）
- 测试 editor 用户（f07r5a_ed@ce-ee.local）：已从 nc_users_v2/nc_base_users_v2/workspace_user/nc_org_users 删除，残留 0
- 含真实 DB 密码的临时 env 文件已销毁（红线）

## 总裁决

int PASS + rev PASS + 实跑门双过 → **本轮 0 error**。
