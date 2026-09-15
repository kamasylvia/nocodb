# r7-f07-lane2 — F07 第 7 轮收敛确认（第 2 路：int 对抗 + rev 复审）

后端 127.0.0.1:8080（nocodb-dev）。f07r7b 账号登录失败（Invalid credentials），按预案回落 f01e2e（super，实测可用）。测试 base 前缀 f07r7b_，测毕全部软删（trash 平台语义），nc_snapshots 零残留，tmp 测试用户已删。

## int 对抗收敛 — PASS

**int-1 非法输入矩阵**（全部实测）
- create title=123 / title={"evil":1}（非 string）→ 400 `Snapshot title must be a string` ✓
- create title 601 字符 → 400 `exceeds 512 characters limit` ✓
- restore 不存在 id → 404 `Snapshot not found` ✓
- delete 不存在 id → 404 ✓
- 跨 base 混用（base A 的 snapshotId 经 base B 路径）：GET / restore / delete → 全 404，且原快照完好（sanity GET completed）✓

**int-2 状态机**
- processing restore → 400 `not ready (status: processing)`。方法：create 后 job 完成过快（<4s）抓不到窗口，改 DB 置 copy base status='job' 触发 deriveStatus=processing；GET 同步派生 processing ✓；测后恢复
- completed restore ×2 → 独立新 base（pdvsm2ib3hqwjgh / pa9p20wbhwv950b，均 live，title `f07r7b_src (restored)`，id 不同）✓
- completed 后副本手动软删（DB 置 deleted=true）→ GET 派生 status=error ✓ → restore 400 `not ready (status: error)`（非 404）✓（cache-free probe 生效：DB 带外改动即时反映）；error 快照 delete 仍 200（copy 已 gone 不 500，R1 容错在位）✓

**int-3 删快照后**
- delete snapshot s2 → 200；copy base API GET 404 + DB deleted=true + nc_snapshots 行删除 ✓
- 变量零残留：nc_base_variables 对全部 f07r7b 相关 copy/restored base（4 id）count=0 ✓
- 源 base 软删（DELETE /api/v2/meta/bases/:id → 200）→ nc_snapshots WHERE base_id=src 清零 ✓；快照副本同步软删（deleted=true）✓；restore 产物 base 存活（独立，deleted=false）✓；源 base 删除后 snapshots API 404（ERR_BASE_NOT_FOUND）✓

**int-4 权限矩阵**
- 无 token：list/create/get/restore/delete → 全 401 ✓
- 非成员用户（f07r7b_tmp，org-level-viewer）：5 端点 → 全 403 ✓
- ACL 注册在位：`src/utils/acl.ts:275-278` creator+ 注释 + 4 权限名
- 备注：首轮自测脚本因 zsh `set --` 不分词误报 400，curl -i 复核实为 401，非服务器行为

**附带实测**：删快照后 list 立即为空（缓存一致性，无幽灵行）✓

## rev 代码复审 — PASS

实跑门：`tsc --noEmit` exit 0（packages/nocodb）✓；jest baseVariableValidators **12/12** ✓

审查对象：`packages/nocodb/src/models/BaseSnapshot.ts`（全文 209 行）、`packages/nocodb/src/services/base-snapshots.service.ts`（全文 291 行）、`packages/nocodb/src/controllers/base-snapshots.controller.ts`（全文 99 行）、关联挂点 `src/models/Base.ts:456-457,706-707`。

逐点核验结果（无可达链，不构成 error）：
1. restore context 依赖 `snapshot.fk_workspace_id`（service:169）——担心列为 null；实测 insert 链 metaInsert2 经 context 自动填充（DB 行 fk_workspace_id=w9qi3ljd 已填），cleanupByBaseIdWithCopies 另有 `?? context.workspace_id` 兜底。正常 API 链不可达 null。
2. create mutex check-then-insert 竞态——代码注释明示 residual risk（最坏双副本、无损坏），历轮已豁免项，本轮不重复报。
3. title 校验：512 上限与表列 varchar(512) 一致；非 string 先型检后 trim（R1 修复在位）；空串/纯空白落默认 title，合理。
4. deriveStatus 统一重派生（R4）：cache-free probe 经 metaGet2 + RootScopes.WORKSPACE（R4 fix 在位），终端态 error 亦重探自愈（L233 `snapshot.status === 'error' ? null : 'error'` 避免重复写）。
5. deleteSnapshot：copy 行存在才 softDelete，gone 仍删登记行（不 500）；Base.softDelete 用快照行 workspace，绕开 Base.delete 首源守卫。
6. BaseSnapshot.insert 先 materialize 再 appendToList（R1 修复在位）；delete 后 list 缓存实测一致；deleteByBaseId deepDel key 与 getList key 格式一致。
7. controller：5 端点 @Acl 齐全且读写分名；v1/v2 双路径一致；MetaApiLimiterGuard+GlobalGuard 与上游 controller 同组合。
8. 源 base 删除清理：Base.delete（L457）与软删路径（L707）双挂点 cleanupByBaseIdWithCopies，实测清零（见 int-3）。

**issues：无**

## 裁决

int PASS + rev PASS → **本路总裁决：PASS（0 error）**
