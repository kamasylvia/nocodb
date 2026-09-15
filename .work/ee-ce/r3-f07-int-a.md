# r3-f07-int-a — F07 Manage Snapshots 第 3 轮会审（第 1 路：集成测试 + 代码复审）

测试对象：当前工作区源码（R3 修复版，`base-snapshots.service.ts` mtime 22:11 / `BaseSnapshot.ts` 22:10 / `Base.ts` 含 `cleanupByBaseIdWithCopies`；运行中 dist 22:13 编译 ≥ 全部 src mtime，进程 22:13:40 起，已验证 bundle 与 src 一致）。
后端 http://127.0.0.1:8080（f07r3a 登录可用但 workspace No Access → baseCreate 403，按预案回落 f01e2e）。DB 直查 pg8000 @ qnap.elf-balance.ts.net:5432/nocodb-dev（未触碰 nocodb 生产库）。

## issues

### F1（int T5 项：DB 直改副本软删后，GET 未派生 error、restore 未 400）

- 位置：`packages/nocodb/src/services/base-snapshots.service.ts:233-242`（deriveStatus completed 探测）、`:119-137`（ensureCopyExists）——两处均经 `Base.get` 探测副本存在性。
- 复现（R3 bundle 实测，2026-09-12 22:1x-22:2x）：快照 completed 后，pg8000 直查 `update nc_bases_v2 set deleted=true where id=<snapshot_base_id>` → `GET /api/v2/meta/bases/:baseId/snapshots/:id` 返回 `status:"completed"`（预期 error）→ `POST .../restore` 返回 200 并给出 base_id（预期 400）。且该 200 为空心成功：restore 目标 base `p6472rn21iclgnq` 因 dup job 源已删而失败，被 processor 自行软删（DB 复核 deleted=true）——用户拿到 200 + 随后消失的 base。
- 根因：`Base.get` 走进程内 PROJECT 缓存（无 NC_REDIS_URL 时 RedisMockCacheMgr）；create/poll 阶段 deriveStatus 已把副本 base 缓存（deleted:false），带外 DB 写不失效缓存 → 探测读到陈旧活对象。缓存冷（实例重启后首查）或删除经任何应用路径（API/trash，缓存被失效）时行为正确：T3/探针实测 API 删副本 → GET 派生 `error`、restore 400「Snapshot is not ready for restore (status: error)」。
- 触发面：仅带外 DB 变更（不受支持的运维路径）可触发；全部应用内删除路径均正确。但 T5 验收项按规格（DB 置 deleted=true → error → restore 400）未达成，判偏离。
- 建议：deriveStatus/ensureCopyExists 的副本探测绕缓存（`runWithoutCache` 包裹，或 `ncMeta.metaGet2` 直查并显式判 `deleted`），或在探测中复核缓存对象 `deleted` 标记并带 TTL 兜底。

### E-ops（环境，不计错误）：会话期间后端多次被并行会话重启/多 rspack 抢 dist/main.js（22:02-22:14 间 8080 多次 000），JWT secret 随重启轮换导致 token 半路 401；测试脚本以连接退避 + 自动重登跑通。另：源码在会话中途更新（22:10-22:11 R3），本路已按最终源码重读复审并重跑双门禁。

## PASS 项（全实测证据）

- T1 全生命周期 PASS：create→`processing`→`completed`（poll trace `[processing,processing]→[completed,completed]`，DB 同步持久化）；副本 base 活、title `Snapshot 2026-09-12T14-15-23 of f07r3int_src`、表/3 行数据与源一致；restore → 新 base `f07r3int_src (restored)` 含同数据；DELETE 快照 200 → GET 快照 404、副本 base 404。
- T2 R2 回归 PASS：源 base API 软删 → pg8000 直查 `nc_snapshots` 该 base_id 行 1→0；源 base GET 404。附加（R3 `cleanupByBaseIdWithCopies`）：删除源 base 连带软删其全部快照副本（f07r3int_src2 的 4 个副本 DB 复核 deleted=true 全真）。
- T3 孤儿快照（副本经 API 删除）PASS：DELETE 快照 200（守卫跳过已删副本，无 500）；GET 先行派生 `error` 并持久化；restore 400。
- T4 PASS：title 非 string 400「Snapshot title must be a string」；513 字符 400；合法 title 200 且 trim。processing 互斥：create 后立即二次 create 400「Another snapshot is still being created. Try again once it completes」。跨 base 隔离：B base 下 GET/restore/DELETE A 的快照全 404。
- T6 PASS：editor 角色 list/create/delete 快照全 403（ACL include 型角色未授予 `baseSnapshot*`；后端 `utils/acl.ts` base scope + 前端 `lib/acl.ts` 一致）。
- rev 读码终核（当前 R3 源码）：deriveStatus 探测先行、15min 超时仅在副本卡 `status='job'` 时触发（R2 项语义正确，job 成功置 status null/失败软删副本，两态均被正确判为 completed/error）；`Base.ts` softDelete/delete 双挂钩均调 `cleanupByBaseIdWithCopies`（ncMeta 贯通事务、副本缺失 try/catch 幂等、动态 import 防循环依赖）；删快照守卫实测 200；R3 createSnapshot 先 derive 再互斥（自愈卡死 processing 行）；controller/module/acl 接线完整，i18n 键 en/zh 各 9/9 命中。
- rev 门禁（R3 后重跑）：`npx tsc --noEmit` exit 0；`npx jest baseVariableValidators --runInBand --forceExit` 12/12 exit 0。
- service/model 其余扫描（仅报 API 可达链）：除 F1 外无洞。mass-assignment（仅 title 白名单）、title 512 = 列宽、跨 base 条件（metaGet2 contextCondition 双保险）、副本的副本链式快照（有限递归无死循环）均核过。

## 清理

f07r3int* 全部 base API 删除（5 活 + 存量软删）；`nc_snapshots` 残留 0；30 个孤儿 schema DROP（按本资源 base-id 精确匹配，未触碰他人 schema）；`schemas_remaining: []`。

## 裁决

int：1 issue（F1，T5 验收项未达成）。rev：0 独立 issue（F1 同时是代码层缓存探测缺口）。总裁决：**不通过（1 error 待修）**——修复 deriveStatus/ensureCopyExists 的缓存探测后需重验 T5 两路径（DB 直删 + API 删）。
