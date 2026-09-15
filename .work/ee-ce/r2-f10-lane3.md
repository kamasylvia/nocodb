# r2-f10-lane3.md — F10 Create Dashboard R2 收敛确认（第 3 路：int 抽验 + 后端终审）

日期：2026-09-12。对象：HEAD=294c79ef5d（6eb3b80c1d F10 CRUD + 294c79ef5d R1 修复）。隔离声明：未读任何 r*.md 历史报告（Write 冲突时系统强制 Read 到本文件 R1 期旧内容，读前本路结论已全部成形；旧内容针对 6eb3b80c1d，其三 error 经现 HEAD 复核均已消解——dashboard-only 路由已移除、insert 缓存顺序已先物化后 append、(base_id,title) 唯一索引已在库）。只读 TASK.md、仓根 AGENTS.md、源码、dev-backend.sh（环境设施）。

实跑门：`tsc --noEmit` EXIT=0；`jest src/helpers/baseVariableValidators.Fork.spec.ts` 12/12 passed。
集成测试：30 项，29 PASS / 1 FAIL（=issues#2）。脚本 `.work/ee-ce/f10-lane3-int.py`（凭证仅 env 注入，未落盘）；DB 直查 pg8000 nocodb-dev（**未触碰 nocodb 生产库**）。

## issues

1. `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts:193`（getMigration switch）：缺 `case 'nc_20260913_dashboard_title_unique'`——import(:80) 与迁移数组(:185) 均已注册，switch 却终于 nc_098 → `getMigration` 返回 undefined。触发链：存量库（xc_knex_migrations 有记录且该迁移 pending）启动时 `src/providers/init-meta-service.provider.ts:102` `await metaService.init()` 无 try/catch → knex `migrate.latest(v2)` 对 pending 迁移解引用 `undefined.up` → TypeError → **启动失败（升级路径阻断）**。fresh install 不受影响（v2 路径跳过；v0 `nc_001_init.ts:381` 已建同名唯一索引；本 nocodb-dev 仅存 xc_knex_migrationsv0，实测未触发，属潜在缺陷）。建议：switch 补 case（照抄 nc_098 模式，一处改动）。

2. `packages/nocodb/src/services/dashboards.service.ts:89`：update 的 title 长度校验用未 trim 的 `body.title.length`，create(:31,:35) 用 trim 后长度 → 同一边界输入两路径行为不一致。**实测复现**：create `"L"*250+" "*10` → 200（落库 trimmed 250）；同串 PATCH → 400 `Dashboard title exceeds 255 characters limit`。无 DB 溢出风险（update 侧更严），纯校验不一致。建议：update 先 trim 再验长，与 create 对齐。

3. `packages/nocodb/src/services/dashboards.service.ts:56`：create 为 check-then-insert，DB 唯一索引已兜底，但 insert 未 catch unique violation（F05 先例 `base-variables.service.ts:78` 有 `isUniqueViolation` catch；`uniqueConstraintErrorHandler` 仅接线 BaseModelSqlv2 数据层，metaInsert2 路径不覆盖）→ 紧竞态下败者 23505 未映射 → 500。本轮 8 并发实测败者均 400（service 检查先胜），该 500 路径未实测命中，属代码级缺口。建议：insert 包 `isUniqueViolation` → badRequest，对齐 F05。

## int 实测（:8080，xc-token，nocodb-dev）

- CRUD 全链过：create（trim 验证、base_id/fk_workspace_id/created_by 正确落库）→list→get→patch(title/description/空体 200)→delete 200→get 404→**pg8000 确认硬删 count=0**→同 title 重建 200
- 校验边界过：无 title/空白/非串 title/非串 description/256 超长 → 400；重名 create/patch → 400
- 跨 base 隔离 5/5 过：baseB get/patch/delete dashA 全 404、B list 空、DB 行未动
- 并发同 title：8 并行 POST → codes=[200,400×7]、DB 恰 1 行、无 5xx（unique 索引在位：pg_indexes 实查 `nc_dashboards_base_title_unique(base_id,title)`）
- base 删除 → `deleteByBaseId` 钩子实测生效（残留=0）；测试数据全清理（残留=0）
- metaDelete = 硬删（meta.service.ts `query.del()`），`deleted` 列为遗留未用，无软删 resurrection 链

## rev 终审

- Dashboard.ts：cache 键 `dashboard:<id>` / `dashboard:<baseId>:list` 合 scope 惯例；insert 先物化单项键再 appendToList（CacheMgr.ts:471-483 核实 PARENT_TO_CHILD deepDel 连子键清除）；`deleteByBaseId` 幂等（重复 metaDelete 0 行无害），Base.ts 双挂点（softDelete 路径 :461、delete 路径 :714）ncMeta 透传正确且实测生效
- controller：5 路由 × @Acl 四 op（dashboardList/Create/Update/Delete）与 `src/utils/acl.ts:280-283`（base scope creator+ 段，与 F05/F07 同段）一致；`modules/noco.module.ts:241/335` 注册在位；路由全部 base-scoped，`:baseId` 由 extract-ids 常规解析（int 404/200 行为佐证）
- op-names 缺 dashboardList、SIDEBAR_FIELDS.dashboardUpdate 缺 description：前者对齐上游惯例（extensionList 同缺，read op 不入 command registry），后者为 scope.ts 注释声明的设计意图（非 sidebar 字段落 entity stack）——均非违反
- metaInsert2 自动注入 base_id/fk_workspace_id/created_at/updated_at，Dashboard.insert extractProps 省略 base_id 无碍（实测落库正确）

## 裁决

issues 3 项：#1 error（升级路径启动阻断，潜在——本库未触发）、#2 minor（实测复现）、#3 minor（代码级缺口，未实测命中）。**不判 PASS**。

**分项：int = 1 FAIL（issues#2）；rev = 3 issues（#1 为 error 级）。总裁决：不通过，需修复后重审。**
