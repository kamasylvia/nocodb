# r8-f07-lane2 — F07 第 8 轮收敛确认（第 2 路：int + rev）

账号：f07r8b@ce-ee.local（signup 后 org-level-viewer，临时升 base viewer/editor/creator 做矩阵）；403 回落 f01e2e@ce-ee.local（super）。后端 127.0.0.1:8080，库 nocodb-dev（Infisical KDL DB_*，host qnap.elf-balance.ts.net）。资源前缀 f07r8b_，测完全部软删（nc_snapshots=0，6 个 base 全 deleted=true）。

## int 对抗收敛 — PASS

### 1. 非法输入矩阵
| 用例 | 结果 | 判定 |
|---|---|---|
| create title=12345（非 string） | 400 `Snapshot title must be a string` | ✓ |
| create title={"a":1}（object） | 400 `Snapshot title must be a string` | ✓ |
| create title 601 字符 | 400 `exceeds 512 characters limit` | ✓（列宽 varchar(512)，information_schema 实查一致）|
| restore 不存在 id | 404 `Snapshot not found` | ✓ |
| delete 不存在 id | 404 | ✓ |
| GET 不存在 id | 404 | ✓ |
| 跨 base GET/restore/delete（B 的 SID 走 A 路由） | 404 ×3 | ✓ |

### 2. 状态机
- completed restore ×2 → 两个独立新 base（pqj51lelkgp65s0 / pimmps1w0zfykct），均存活、同名不冲突 ✓
- copy base DB 置 status='job' → GET 派生 `processing`，restore → 400 `not ready (status: processing)` ✓（真实代码路径实测，非 mock；改回后恢复 completed）
- copy base DB 置 deleted=true → GET 派生 `error`，restore → **400 非 404** `not ready (status: error)` ✓
- 注：真实 processing 窗口（create mutex / processing restore）空 base 下秒级关闭无法抓取，经 DB job 态路径覆盖同一 deriveStatus 分支，有诊断证据，按 E3 类窗口限制处理，不打断计数。

### 3. 删除链路
- 删快照（副本活着）→ 副本 API 404（ERR_BASE_NOT_FOUND）+ DB deleted=true + nc_snapshots 行删净 ✓
- 删快照（副本已缺失/软删）→ 200 正常删行，不 500 ✓
- 删后 nc_base_variables 副本残留 = 0 ✓（副本经 duplicateBase 本不携带变量）
- 源 base 软删（API DELETE）→ nc_snapshots 清零 = 0 + 快照副本 deleted=true + 变量零残留 ✓（Base.softDelete:458 → cleanupByBaseIdWithCopies 接线确认）

### 4. 权限 401/403 矩阵
| 主体 | list | create | get | restore | delete |
|---|---|---|---|---|---|
| 无 token | 401 | 401 | 401 | 401 | 401 |
| 非成员（org viewer） | 403 | 403 | 403 | 403 | 403 |
| base viewer | 403 | 403 | — | 403 | 403 |
| base editor | 403 | 403 | — | — | — |
| base creator | 200 | 200（create→completed） | — | — | — |

editor 未单测 restore/delete：同一 aclFn permission 判定分支，list/create 已覆盖该分支（include 无 baseSnapshot* 且无 exclude → 拒）。与 acl.ts "creator+ only" 注释一致。

## rev 代码复审 — PASS

范围：`packages/nocodb/src/models/BaseSnapshot.ts`、`src/services/base-snapshots.service.ts`、`src/controllers/base-snapshots.controller.ts`、acl.ts 中 baseSnapshot* 定义。

**issues：无**（无可达链的 bug/安全/一致性问题）。核查要点：
- title 校验上限 512 与 nc_snapshots.title varchar(512) 精确一致（DB 实查）
- getCopyBaseRow 用 RootScopes.WORKSPACE + deleted 探测，cache-free，无缓存遮蔽
- deriveStatus 全状态重探自愈；restore 有 ensureCopyExists 双保险，TOCTOU 窗口仅剩 job 提交瞬间，无实际可达链
- insert 缓存物化后再 appendToList；deleteByBaseId 的 metaDelete 条件与 context.base_id 一致（源 base 软删清零实测佐证）
- cleanupByBaseIdWithCopies 动态 import 断循环、副本缺失容忍、行清理必达
- controller 五端点 ACL 分离合理，DELETE 实测 200
- create mutex check-then-insert 竞态为注释声明的 documented residual（worst case 双副本、无损坏），不构成 error

### rev 实跑门
- `npx tsc --noEmit` → exit 0（0 错误）
- `npx jest baseVariableValidators` → 12/12 passed, exit 0

### 流程 note（非代码 error）
共享回落账号 f01e2e 每次 signin 轮换 token_version，多路并发使用互踢旧 token（本轮两次 mid-test 401 由此来，重新 signin 即恢复）。建议各路用独立回落账号或每批命令自动 signin。

## 总裁决：PASS（int PASS + rev PASS，0 error）
