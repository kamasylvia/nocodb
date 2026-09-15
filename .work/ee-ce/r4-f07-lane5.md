# r4-f07-lane5 — F07 Manage Snapshots 第 4 轮会审（第 5 路：集成测试 + 代码复审）

日期：2026-09-12。范围：`git status --short` 全部 14 修改 + 3 未跟踪新文件。
隔离声明：未读 `.work/ee-ce/` 下任何 r*.md 报告；只读 TASK.md、仓根 AGENTS.md、源码、流程脚本（dev-backend.sh / 既有 e2e 脚本仅参考 API 形状与登录方式）。
测试件：`.work/ee-ce/lane5-tmp/`（l5_lib.py / l5_t1_chain.py / l5_t2_perm.py，独立账号 l5r4ed_*，独立 base，未触碰他路数据）。

---

## issues

### E1（error，HIGH，API + DB 双重实证）
`packages/nocodb/src/services/base-snapshots.service.ts:258`（`getCopyBaseRow`）：
以请求 context（`context.base_id` = 源 base id）调 `Noco.ncMeta.metaGet2(..., MetaTable.PROJECT, snapshotBaseId)`。
`meta.service.ts:266` `contextCondition` 对 `target === PROJECT` 会追加 `WHERE id = <context.base_id>`，与 `metaGet2` 自身的 `WHERE id = <snapshotBaseId>` 叠加为 `id=源base AND id=副本base` → **恒空集**。

后果（全链路实测，nc_snapshots id `snap507h6xn3cz5cf7`，源 base `p0z4c2n3e66di8w`，副本 `pk6o9kpj4xh17ks`）：
1. `deriveStatus` 恒走 `copyRow == null → 'error'`：DuplicateBase job 实际成功（副本 base 已建出、`deleted=false`、title `Snapshot ... of ...` 正确），快照仍被标 `error`（DB 复核 `nc_snapshots.status='error'`）。
2. `restoreSnapshot` 恒 400 `Snapshot is not ready for restore (status: error)`。
3. `deleteSnapshot` 走 `copyRow==null → skip softDelete` 分支：只删登记行，**副本 base 残留为活的未管理 base**（含源 base 全量数据副本 → 数据驻留面）。实测删快照后 `nc_bases_v2.deleted=false` 残留。
4. 交叉印证（同库他处快照，非本路创建）：R3 fix 部署前（21:40）的快照 `completed`，R3 fix 部署后（22:40 / 22:50）的快照全部 `processing`/`error` —— 回归由 R3 的「cache-free probe」引入。

SQL 实证：`SELECT count(*) FROM nc_bases_v2 WHERE fk_workspace_id='w9qi3ljd' AND id='<源>' AND id='<副本>'` = 0 行（等价于 metaGet2 实际下推条件）；仅按 id 查则命中。

建议：`getCopyBaseRow` 改用跨 base scope —— `metaGet2(workspace_id, RootScopes.WORKSPACE, MetaTable.PROJECT, snapshotBaseId)`（contextCondition 对非 PROJECT 表不追加 base 条件、对 `base_id===RootScopes.WORKSPACE` 提前返回，仅剩 `fk_workspace_id + id` 两条件），或直接 `metaGet2(RootScopes.FULL_BYPASS, RootScopes.FULL_BYPASS, ...)` 后自行校验 `fk_workspace_id`。修复后需重测：create→completed、restore 200、delete 后副本 `deleted=true`。

---

## PASS 项（证据摘要）

### int（集成，nocodb-dev，pg8000 直查逐步核验）
- **secret 变量安全链**：源 base 建 secret 变量 `L5_SECRET` → DB `nc_base_variables.value='U2FsdGVkX1/...'`（非明文，dev 注入 `NC_CONNECTION_ENCRYPT_KEY` 生效）→ 快照副本 base variables 行数=0 → restore 产物 variables 行数=0 → 全库 `value LIKE '%<明文>%'` sweep 无扩散。AGENTS §2.1「F07 无 secret 物料通道」实测证实。
- **删源 base cleanup**（`Base.delete` → `cleanupByBaseIdWithCopies` hook，该路径不受 E1 影响）：副本 base `deleted=true` ✓、`nc_snapshots` 登记行清空 ✓、源 base variables 行清空 ✓。
- **权限**：无 token / 坏 token 401（GET/POST/restore）；base 级 editor 邀请后 list/create/restore/delete 全 403；跨 base 访问外部 snapshot id 404；owner/creator 全链路 200。
- 边界说明：401 首测误用不存在 base 得 404（用例路径问题，非产品问题），换真实 base id 复测 401 通过。

### rev（终审）
- **一致性**：`Api.ts` / `ncUtils.ts`（`isEeUI`）未动（`git diff --name-only` 为空）；`BaseSettingsMenu.vue` 移除 `isEeUI &&` 属 gating 由 `isEeUI` 换 `blockSnapshots` 的预期替换，非翻转常量。`[CE-EE]` 标记：所有修改 hunks 覆盖；3 个新文件有文件级头标记（与 F05 先例一致）；lang/*.json 与 `models/index.ts` 行无标记与 F05 commit（6ab23da0）先例逐字一致。
- **acl 双侧一致**：前端 `lib/acl.ts` `baseSnapshot*` 挂 CREATOR include（OWNER 经 cascade 继承）；后端 `utils/acl.ts` 挂 `permissionScopes.base` 全集，CREATOR/OWNER 为 exclude 模式自动获得、EDITOR 为 include 白名单天然不含 —— 与实测 editor 403 / creator-owner 200 完全吻合。
- **测试基建**：`npx tsc --noEmit` exit 0；jest 实跑 2 suites 26/26 PASS（`baseVariableValidators.Fork.spec.ts` + `uniqueConstraintHelpers.Fork.spec.ts`，58s）。
- **backend.log**：存在 5 个 `ERROR in ./src/services/base-snapshots.service.ts` TS2339 块（`copyBaseExists`/`getCopyBaseRow` 中间态，均在 line 2079 之前）；最后一次 rspack 编译（line 5232）之后 0 ERROR，当前编译干净（唯一 warning 为上游 require-in-the-middle，与本功能无关）。其余为 Token Expired 401 认证噪音（dev server 重启轮换 JWT 的正常拒绝）。
- **`dataHelpers.ts` base undefined 守卫**：`NcError.baseNotFound` 存在且为 `never`（throw 型），tsc 0，无返回后续航问题。
- **缓存正确性**：`BaseSnapshot.deleteByBaseId` 的 `deepDel` key `snapshot:<baseId>:list` 与 `CacheMgr.getList` 组装 key 逐字匹配（`filter(k=>k)` 无空 subKey 风险）。
- **AGENTS §2.1**：副本 title 前缀 / nc_snapshots 登记 / restore 语义 / 「快照不复制 base variables」均与代码和实测一致。E1 修复前「删快照 = softDelete 副本」与实际行为有偏差，随 E1 一并消除，不单列文档 issue。
- **commit 前清单**：14 修改 + 3 新文件均属 F07 语义；`.work/` 未出现在 git status（已忽略，凭证仅 0600 落 lane5-tmp/env.sh，不入 git）。观察项（非 error）：`nuxt.config.ts` 的 `allowedHosts: true` 为 dev 基建改动混入本功能 diff，commit body 建议提一句；`createSnapshot` UI 轮询上限 24×2.5s=60s，大 base 超 60s 时 UI 停留 processing，属可接受（重进页面收敛）。

---

## 裁决

- **int：FAIL**（E1 实测复现，HIGH）
- **rev：FAIL**（E1 安全后果：快照副本以活 base 形态残留，数据驻留 + 快照核心语义失效；其余审查面全 PASS）
- **总裁决：NOT PASS —— 1 个实际 error（E1），必须修复后重开新一轮 5 路会审**（本轮计 error，计数归零）
