# r6-f07-lane2.md — F07 第 6 轮收敛确认（第 2 路：集成测试 + 代码复审）

- 日期：2026-09-12
- 范围：commit bc409929da + 6eb3b80c1d（F07 snapshots）；复审对象 `packages/nocodb/src/models/BaseSnapshot.ts`、`src/controllers/base-snapshots.controller.ts`、`src/services/base-snapshots.service.ts`、`src/models/Base.ts`（hook）、`src/utils/acl.ts`
- 环境：dev server :8080（nocodb-dev），测试脚本 `.work/ee-ce/lane2-tmp/f07l6l2_*.py`，用户 f07l6l2a/b/c@ce-ee.local，测后残留已清理（OTH + 3 个 restored base 删除，lane2 快照行 0）
- 隔离声明：未读任何 r*.md 报告；只读 TASK.md、仓根 AGENTS.md、源码、运行系统
- 注：本路径原有早前 lane2 实例（f07r6b 前缀）完整报告，已备份至 `r6-f07-lane2-prev-f07r6b.md`；本次为重派完整轮。前份报告的 1 项 edge 级发现（restore 进行中删快照 → DuplicateBase catch 对已返回的 restored base 执行 softDelete，产物落 trash）本轮对抗矩阵未覆盖、维持其原始实测结论，供裁决汇总参考

## int — 集成测试（对抗收敛）

### T1 非法输入矩阵（14/14 PASS）

| 项 | 结果 |
|---|---|
| create title=123 / {a:1} / ["x"] / null → 400 | PASS ×4（`Snapshot title must be a string`） |
| create title 601 字符 → 400 | PASS（512 上限拦截） |
| create title 512 字符（边界）→ 200 | PASS |
| get/restore/delete 不存在 id → 404 | PASS ×3（`Snapshot not found`） |
| 跨 base 混用（SRC 快照走 OTH 路径 get/restore/delete）→ 404 | PASS ×3 |
| 自 base 正常 delete → 200，复删 → 404 | PASS ×2 |
| 空 body 默认 title（`Snapshot <ts>`）→ 200 | PASS |

### T2 状态机

| 项 | 结果 | 说明 |
|---|---|---|
| create 返回 status=processing | PASS | |
| processing 窗口内 restore | 首测 200（FAIL） | **定性非缺陷**：小 base duplicate job 毫秒级完成，restore 到达时快照已真实 completed；restore 产物 `pz8p00qze6tzjsf` 经验证为有效完整副本（live、标题正确、表数与源一致） |
| 受控补测：副本置 status='job' → get=processing、restore→400 | PASS | `Snapshot is not ready for restore (status: processing)` |
| status='' → 自愈 completed | PASS | |
| completed restore ×2 → 独立新 base | PASS | 两个不同 base_id，均 live |
| 副本手动软删（PG deleted=true）→ get status=error | PASS | |
| purge 后 restore → 400（非 404） | PASS | `Snapshot is not ready for restore (status: error)` |

### T3 删快照残留 + 源 base 软删清零

| 项 | 结果 | 说明 |
|---|---|---|
| 带表快照：副本表数=源表数（1=1） | PASS | |
| delete snapshot → 200，get → 404 | PASS | |
| 副本 base API get → 404（ERR_BASE_NOT_FOUND） | PASS | |
| 副本 DB deleted=true | PASS | |
| 副本 nc_base_variables 计数=0（零残留） | PASS | 全部 6 个副本合计=0 |
| 源 base 软删 → nc_snapshots 按 base_id 清零 | PASS | `WHERE base_id=SRC` = 0 |
| SRC 全部快照副本连带软删 | PASS | |
| restored bases（restore 产物）不受源删除影响 | PASS | RB1/RB2/race-base 全 live |
| 脚本级 FAIL ×2（snaps_cleared_global / all_copies_soft_deleted） | 归因测试口径错误 | 误查全局 nc_snapshots（含历史 lane 残留行，属 f07_src_*/f07del/f07r3a 等其它 base）；DB 复查确认 SRC 自身清零、SRC 副本全软删。**非产品缺陷** |

### T5 权限矩阵（18/18 PASS）

| 角色 | create/list/get/restore/delete | 结果 |
|---|---|---|
| 无 token | 全部 → 401 ERR_AUTHENTICATION_REQUIRED | PASS ×5 |
| editor（base 内 editor 角色） | 全部 → 403 ERR_FORBIDDEN | PASS ×5 |
| no-access（登录但无 base 角色） | list/create → 403 | PASS ×2 |
| creator | create/list/get/delete → 200 | PASS ×4 + invite 200 + cleanup 200 |

## rev — 代码复审（BaseSnapshot.ts / controller / service）

**实跑门**：
- `npx tsc --noEmit` → exit 0（0 错误）
- `npx jest baseVariableValidators` → 12/12 passed

**复审结论：无（无可达缺陷链）**。逐点核验：

1. `BaseSnapshot.deleteByBaseId` 的 deepDel 键（`snapshot:<baseId>:list`）与 `getList`/`appendToList` 键构造（`nc:<ws>:<base>:snapshot:<baseId>:list`）逐层比对一致（NocoCache.ts:11-27 cacheContext + CacheMgr.ts:277-280）；PARENT_TO_CHILD 对已含 `:list` 后缀的键不重复追加（CacheMgr.ts:482）。cache 清理正确。
2. `Base.get` 查询条件含 `deleted: false` 且 cache 命中路径二次校验 `baseData.deleted`（Base.ts:290/301-303）→ 软删 base 无法 createSnapshot（返回 404）。无 trash-base 建快照洞。
3. `restoreSnapshot` 状态门（deriveStatus→非 completed 400）+ `ensureCopyExists`（completed 后 duplicateBase 前的 TOCTOU 二次验证）双层防御；deriveStatus 全状态 cache-free 重探（getCopyBaseRow 直查 nc_bases_v2，RootScopes.WORKSPACE 上下文正确），purge 副本降级 error 且 400 非 404，实测吻合。
4. controller 5 端点全部挂 `@Acl`（create/restore/delete 专属权限、get 复用 list 权限），与 acl.ts base scope creator+ 白名单一致；401/403 实测全过。
5. `cleanupByBaseIdWithCopies` 在 Base.softDelete（Base.ts:458）与 delete（Base.ts:711）两路径均挂接；副本软删失败（已消失）被吞、行清理必达——实测源删后零残留。
6. title 校验（非 string 400 / >512 400 / trim 空→默认值）、copy base title 150 截断，无注入面（参数化）。
7. 观察项（非违反）：`deriveStatus` 为惰性派生——孤儿 processing 行（历史轮遗留）只在 API 触碰时自愈，DB 层不主动扫描；与设计一致，无需修。

## 裁决

- **int：PASS**（50 项实测，0 产品缺陷；2 个脚本口径 FAIL 已归因为测试自身错误，1 个竞态观察定性为非缺陷并经受控补测闭环）
- **rev：PASS**（实跑门 tsc 0 + jest 12/12；代码复审无可达洞）
- **总裁决：PASS（0 error）**
