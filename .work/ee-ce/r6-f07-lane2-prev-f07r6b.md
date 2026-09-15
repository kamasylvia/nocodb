# r6-f07-lane2（第 2 路：int 对抗收敛 + rev 复审）

日期：2026-09-12。后端 127.0.0.1:8080（f01e2e@ce-ee.local 回落账号，f07r6b 专用账号登录失败 Invalid credentials）。资源前缀 f07r6b_，测完已全删（DB 复核 bases/snapshots/variables 零残留，API token id=7/8 已删）。

## 裁决：issues（1 项，edge 级，单路发现+实测复现，按纪律不入计数）

### issues 列表

1. `packages/nocodb/src/services/base-snapshots.service.ts:138`（restoreSnapshot）联动 `packages/nocodb/src/modules/jobs/jobs/export-import/duplicate.processor.ts:339`（catch 块）: restore 进行中删除该快照无任何互斥/标记 → restore 的 DuplicateBase job 读到已软删副本而失败 → processor catch 对已随 200 响应返回给客户端的 restored base 执行 baseSoftDelete → 用户拿到的 base_id 成了 trash 里的半成品（实测：restore 200 返回 base_id 后 7s 删快照，DB 终态 `deleted=true, status='job'`；对照干净 restore 产物存活正常，确证为该竞态）。: 建议 restore 启动时在快照行置 restoring 标记并让 deleteSnapshot 遇标记 400；最低限度在 AGENTS §2.1 文档化为 fork 已知限制（副本删除语义下进行中的 restore 产物作废进 trash，可从 trash 恢复但内容可能残缺）。

### rev 其余范围：无

BaseSnapshot.ts（cache list/insert appendToList/update extractProps/deleteByBaseId deepDel key/cleanupByBaseIdWithCopies 动态导入防环+softDelete 容错）与 base-snapshots.service.ts（title 校验、mutex 基于派生后状态、deriveStatus 统一重派生、15min 超时安全网+自愈、getCopyBaseRow RootScopes.WORKSPACE 修正、deleteSnapshot 死副本容错）、controller（v1/v2 双路由、5 端点 ACL 全接、@HttpCode(200)）：无可达问题链，不报。

## int 实测记录（全部 PASS）

环境坑（非 F07 问题，不计）：dev server 期间重启 2 次，JWT secret 不固定 → 401 抖动；测试改用 API token（org 级 xc-token）完成。

1. 非法输入矩阵 10/10：
   - create title=123 → 400 `Snapshot title must be a string`；title=[] → 400；title 601 字符 → 400 `exceeds 512 characters limit`
   - restore / delete / get 不存在 snapshotId → 404 ×3 `Snapshot not found`
   - 跨 base（他 base URL + 存在快照 id）get / restore / delete → 404 `Snapshot not found` ×3（快照存在性不泄露）
2. 状态机：
   - processing restore → 400（DB 置副本 status='job' 构造真实 processing 窗口；自然窗口对 1 表 base 仅数秒，首轮 200 为 job 已完成非绕过）`Snapshot is not ready for restore (status: processing)`
   - processing create（mutex）→ 400 `Another snapshot is still being created`
   - completed restore ×2 → 两个独立新 base（id 不同、同名、均存活 deleted=false status=''）
   - 副本 DB 手动软删（pg8000 nocodb-dev 直查，host qnap.elf-balance.ts.net，未触碰 nocodb 生产库）→ GET 派生 error → restore 400（非 404）；list 同步派生 error
   - 僵尸 processing 行（副本实际已完成）GET → 派生自愈为 completed
3. 删快照与级联：
   - 活副本场景：DELETE → 200；副本 base API 404；DB deleted=true；nc_base_variables 1→0（删前预置 secret 变量 F07R6B_V1）；快照行删除；再 GET 快照 404
   - 死副本场景（error 快照）：DELETE → 200 不 500
   - 源 base 软删（DELETE /api/v2/meta/bases/:id）：nc_snapshots 该 base 行 → 0；残留快照副本软删（cleanupByBaseIdWithCopies 生效）
4. 权限矩阵 7/7：无凭据 401；伪造 token 401；org-level-viewer（f05r4b）list/create/get/restore/delete 全 403 `Forbidden - Unauthorized access`（ACL creator+ 一致）

## rev 实跑门

- `npx tsc --noEmit`（packages/nocodb）→ exit 0
- `npx jest baseVariableValidators` → **12/12 passed**（1 suite）

## 资源清理复核

- 存活 f07r6b* base：0；f07r6b 快照行：0；F07R6B* 变量：0；API token 7/8：已删
- 其余 nc_snapshots 既有行（他 lane 历史资源）未触碰
