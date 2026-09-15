# r3-f07-rev-c — F07 R3 第 5 路会审报告（int 交叉抽验 + rev 交叉面终审）

日期：2026-09-12（完整重做版，覆盖同名前次未返回裁决的旧稿；本版含其后全部实测）。

隔离声明：未读任何 r*.md 报告；只读 TASK.md、仓根 AGENTS.md、源码、流程脚本（dev-backend.sh 与既有 f07 流程脚本仅取账号/端点约定）。集成测试自建于 `.work/ee-ce/tmp-r3c5/`：DB 凭证运行时经 Infisical KDL 拉取、不落盘；pg8000 只直查 `nocodb-dev`，未触生产库。测试资产已清理（全部 deleted=true 进 trash，无活残留）。

改动面核验：`git status --short` = 13 M + 3 未跟踪（base-snapshots.controller.ts / BaseSnapshot.ts / base-snapshots.service.ts），与 TASK 改动面一致。

## int（交叉抽验）结论

全链路 API + pg8000 直查 nocodb-dev 逐步核验，全部通过：

| 步骤 | 结果 | DB 证据 |
|---|---|---|
| setup | 源 base `f07r3c5_src`（1 表 5 行）+ secret 变量 `R3C5_SECRET` | `nc_base_variables` 1 行 type=secret，value=`U2FsdGVkX1+…`（NC_CONNECTION_ENCRYPT_KEY 加密落库生效） |
| T1 create | POST snapshots → 200 status=processing；2.5s 轮询收敛 completed；list 200 count=1 | `nc_snapshots` 行 base_id/snapshot_base_id/created_by/status=completed 全对；副本 `nc_bases_v2` title=`Snapshot 2026-09-12T13-56-45 of f07r3c5_src`、status 已脱离 job；**副本 `nc_base_variables` = 0 行**（secret 物料无复制通道，AGENTS §2.1 声明实证） |
| T2 restore | POST restore → 200 {base_id}；restored base tables=1、records=5（row0–row4）；variables=0 | `nc_bases_v2` title=`f07r3c5_src (restored)` deleted=false。注：restore 返回后立即 API 查表为 0（异步复制时序），20s 后 DB+API 均可见，非缺陷 |
| T3 delete | DELETE → 200 true；list 0；registry 行 0 | 副本 `nc_bases_v2.deleted=true`（trash 语义，非物理删） |
| T4 源 base 删除（双挂钩） | DELETE base → 200；**nc_snapshots 行清理（Base.delete 挂钩实证生效）** | 顺带发现孤儿副本 issue-1（见下） |
| T5 权限 | 无 token → 401 ERR_AUTHENTICATION_REQUIRED；非成员用户 GET/POST/restore/DELETE → 403×4；**editor（base 成员）→ 403×4**（baseSnapshot* ACL creator+ 生效）；editor 读快照副本 base → 404（副本成员不随复制扩散，无越权读） | — |
| T6 title 边界 | title=12345 → 400（R1 修复有效）；title 600 字符 → 400 | — |

环境备注：会审期间 dev server 两次被并行路触发的 rspack 重启竞争搞挂（RunScriptWebpackPlugin，AGENTS §3.2 已知），按 dev-backend.sh 同种进程重启恢复，不影响结论。

## rev（交叉面终审）结论

**安全**
- 副本可见性：副本为 workspace 内普通 base；editor 404 / creator 200；副本无 variables（无 secret 物料）。PASS
- restore creator-only：T5 editor 403×4 实证；restore 前置 status=completed 校验。PASS
- delete trash 残留：副本 softDelete（deleted=true）+ registry 删 + 副本 variables 清理挂钩路径，DB 三项实证。PASS

**一致性**
- `[CE-EE]` 标记：13 个改动文件全部修改处均有标记（含 View.vue watch 行、BaseSettingsMenu 解构行）；3 个新文件头部有说明注释。PASS
- Base.ts 双挂钩：Base.delete（约 L456）与 Base.softDelete（约 L706）均新增 `BaseSnapshot.deleteByBaseId`；T4 实证挂钩执行。PASS
- Api.ts / ncUtils.ts（isEeUI）：git status 未涉及，未动。PASS
- acl 双侧：后端 `utils/acl.ts` creator scope 与前端 `lib/acl.ts` ProjectRoles.CREATOR 块同加 baseSnapshotList/Create/Restore/Delete；EDITOR 及以下无；controller 五路由 ACL（Create/List/List/Restore/Delete）一致；前端页面级 gate 用 baseSnapshotList（creator 一票全权）双侧自洽。PASS
- 缓存键：`deleteByBaseId` 的 deepDel 键 `snapshot:<baseId>:list` 与 `NocoCache.getList/setList` 键格式（`${scope}:${subKeys.join(':')}:list`）匹配。PASS
- metaGet2/base_id 语义：context 条件过滤 + `getSnapshotWithBaseCheck` 校验 snapshot.base_id===URL baseId 双保险。PASS

**测试基建**
- `npx tsc --noEmit` 退出码 0（独立实跑）；rspack `[type-check] no errors found` 双证。PASS
- jest 实跑 2 suites / 26 tests 全过（Fork 桶：baseVariableValidators / uniqueConstraintHelpers；F07 无专属 spec，其逻辑依赖 DuplicateBase job 属集成性质，本轮集成测试已实测覆盖）。PASS
- backend.log（覆盖 T1–T6 全程）无非 auth 噪音的 ERROR/500，无 F07 相关错误残留。PASS

**文档（AGENTS §2.1）**
- 四条声明全部实测证实：副本 title 前缀 `Snapshot <ts> of` ✓、restore 产物名 `<orig> (restored)` ✓、快照不复制 base variables ✓、删快照走 softDelete 进 trash ✓；引用 commit 6ab23da0/744d3161 存在。PASS

**commit 前清单**
- 13 改动 + 3 未跟踪全部逐一过目（diff 全文 + 新文件全文），无未审面。PASS

## issues

1. `packages/nocodb/src/models/Base.ts:456,706`（挂钩语义面）：源 base 删除时 `BaseSnapshot.deleteByBaseId` 只清 registry 行，不处理各 `snapshot_base_id` 副本 base —— T4 实测副本残留为 workspace 活 base（title `Snapshot <ts> of <已删base>`，deleted=false），registry 已删致无法再经快照 API 管理该副本。建议：挂钩内对每个待删 registry 行的 snapshot_base_id 追加 `Base.softDelete`（副本进 trash，与删快照语义对齐），并同步 AGENTS §2.1。定级 warning（无越权、无 secret 物料、creator 可手动清理；但若多路独立同报此问题，按 ≥2 路规则升必修）。
2. `packages/nocodb/src/services/base-snapshots.service.ts:55-76`：`duplicateBase` 成功后 `BaseSnapshot.insert` 若失败（DB 异常），副本已落地但无登记行，成为不可管理孤儿（existing mutex 注释未覆盖此路径）。建议 insert 包 try/catch 失败补偿 softDelete，或注释声明残余风险。定级 warning（代码审读推断，未复现）。
3. `packages/nc-gui/nuxt.config.ts:160-167`：`vite server.allowedHosts=true` 进 git 对所有开发者 dev 环境生效（理论 DNS rebinding 面仅限本机 dev server）；注释已声明 dev-only 且 trycloudflare host 随机无法枚举。定级观察项（可接受）。

## 裁决

- **int**：PASS（快照全链路 create→restore→delete + 权限 401/403 + 边界，每步 DB 核验全过）
- **rev**：PASS（安全 / 一致性 / 测试基建 / 文档 / commit 清单五面全过；3 项 warning/观察级，0 error）
- **总裁决**：**PASS（0 error）**。issue-1/2 为 warning 级（建议随下轮或收尾批次处理；issue-1 若他路独立同报则升必修），不阻断 F07 连续 0 error 计数。
