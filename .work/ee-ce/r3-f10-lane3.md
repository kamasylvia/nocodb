# r3-f10-lane3 — F10 R3 会审（第 3 路：int 抽验 + rev 后端终审）

日期：2026-09-12。范围：`git diff` 工作树 4 文件（Dashboard.ts / dashboards.service.ts / XcMigrationSourcev2.ts / nc_001_init.ts）+ F10 全量后端面。隔离声明：未读任何 r*.md 归档报告。

## 实跑门

- `npx tsc --noEmit`：exit=0，0 error（log: .work/ee-ce/logs/lane3-tsc.log）
- `npx jest --testPathPattern baseVariableValidators`：**12/12 passed**（1 suite）

## int 抽验（API 实测 @ :8080 + pg8000 直查 nocodb-dev）

脚本：`.work/ee-ce/lane3-tmp/f10r3_lane3_int.py`（凭证运行时取自 Infisical KDL DB_*，host=qnap.elf-balance.ts.net，db=nocodb-dev，未触碰生产库）。**31/32 pass**。

通过项（抽样）：
- DB：`nc_dashboards_base_title_unique` 唯一索引在库（CREATE UNIQUE INDEX ... btree (base_id, title)）；创建行落库 title 已 trim、base_id/created_by 正确
- CRUD：create(trim)/list/get/patch title/patch desc/patch 空 body/delete→get 404→行硬删→同 title 可重建，全过
- 校验：create 无 title/空白/非 string/非 string desc/256 长 → 全 400；update 空白 title → 400；patch 重复 title → 400
- 跨 base 隔离：baseB 视角 get/patch/delete baseA 的 dashboard → 全 404，DB 行无损；baseB list 空
- 并发同 title：8 线程并发 create → codes=[200,400×7]，DB 恰 1 行，无 5xx
- base 删除级联：deleteByBaseId 钩子生效，dashboard 行清零；清理后无残留

## rev（后端终审）

- `models/Dashboard.ts`：insert 顺序 metaInsert2→get→appendToList 与 BaseVariable/Extension 惯例一致；cache 键 `${dashboard}:${id}`（get/update/softDelete/delete CHILD_TO_PARENT）；`deleteByBaseId` deepDel `${dashboard}:${baseId}:list` PARENT_TO_CHILD 与 `Extension.deleteByBaseId` 逐字对齐；Base.ts softDelete(:461)/delete(:714) 均挂清理钩子；R3 diff 的 `getWidgets` 落 `this.widgets=[]` 修复了 export.service.ts:122 `for (const widget of dashboard.widgets)` 对 undefined 迭代的导出崩溃（可达链实测存在：base export 必经 serializeDashboards）
- migration：`nc_20260913_dashboard_title_unique.ts` up 先按 created_at 去重再建唯一索引、down 可逆；import/names/case 三处在位；nc_001_init 新库同款唯一约束
- service：create 全类型守卫齐；update 重复 title 检查用 trim 后比较、与自身 id 互斥正确；description string|null 守卫齐
- controller：5 路由 ACL（dashboardList/Create/Update/Delete）均在 acl.ts creator+ 块，与 F05/F07 同块；getDashboardWithBaseCheck 跨 base 404 兜底实测有效

## issues

1. `packages/nocodb/src/services/dashboards.service.ts:87`：update 路径对 `body.title` 缺 `typeof !== 'string'` 守卫，`(body.title as string).trim()` 对非 string（如 `123`/`{}`）抛 TypeError → **500**（实测复现：`PATCH .../dashboards/:id` body `{"title":123}` → 500 `innerError.msg="body.title.trim is not a function"`）。create 路径（:28-30）有同款守卫返回 400，两路不一致。建议：update title 分支开头加与 create 相同的 typeof 守卫后再 trim（连带 ：99/:103/:109 三处 `body.title.trim()` 同源）。
2. `packages/nocodb/src/services/dashboards.service.ts:56`（create）/`:108`（update）：`Dashboard.insert/update` 未按 `isUniqueViolation` 映射 DB 唯一约束冲突。check-then-insert 紧竞态下（双请求同过 ：49/:96 预查）后到者吃裸 pg 23505 → 500；本轮 8 线程实测未触发（预查均赶上已提交行，全 400），但 metaInsert2 无兜底映射（src/meta/meta.service.ts:301 直插不捕）。F05 同型已修（base-variables.service.ts:78-84，注释明确「two creators racing → same 400 instead of 500」）。建议：create/update 包 try/catch + `isUniqueViolation(e)` → `NcError.badRequest('... already exists in this base')`，与 F05 对齐。

## 裁决

- **int**：31/32，唯一 FAIL 即 issue 1（同源），其余全过 → 有 1 error
- **rev**：issue 1 实测复现属实（可达链 + 500 违反「无效输入不 500」验收项）；issue 2 为 F05 惯例对齐缺口（本轮未实测复现，链路存在）
- **总裁决：issues（不 PASS）** —— issue 1 必修（单路属实经实测验证亦修）；issue 2 建议同批修（低风险、防紧竞态 500）。修复后重审。
