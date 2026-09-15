# r2b-f10-lane3 — F10 R2 会审(第 3 路:集成抽验 + 后端终审)

## issues

1. `packages/nocodb/src/models/Dashboard.ts:192` — `getWidgets` stub 只 `return []`,不赋 `this.widgets`;`export.service.ts:126` `for (const widget of dashboard.widgets)` 对 undefined 迭代 → TypeError。**已实测**:对含 4 个 dashboard 的 base 跑 `POST /api/v2/meta/duplicate/:baseId`,job `joboreze8jvrrwckr` FAILED,日志原文 `TypeError: dashboard.widgets is not iterable at ExportService.serializeDashboards (export.service.ts:126)`。可达链:① base duplicate(duplicate.processor.ts:211,`!options.excludeDashboards` 默认走);② **F07 snapshot create/restore 回归**(base-snapshots.service.ts:60/169 均 `options: {}` → 同炸);③ base export/migrate(migrate.service.ts:97)。fork 前无此问题(CE stub `list` 恒返 `[]`,循环体不进),F10 实化 `list` 后暴露。建议:`getWidgets` 内 `this.widgets = []; return this.widgets;`(与该字段 transient 注释语义一致)或 `export.service.ts:126` 改 `dashboard.widgets ?? []`。
   附注:同次 job 失败后 catch 清理在 `duplicate.processor.ts:341` `baseSoftDelete` 抛 baseNotFound 成为 surfaced stack——根因同上,修复后自消。

2. `packages/nocodb/src/meta/migrations/v0/nc_001_init.ts:1410` — fresh-install 建表路径无 `(base_id, title)` 唯一索引;唯一创建点是 v2 迁移 `nc_20260913_dashboard_title_unique`,而 `meta.service.ts:1133` gate 仅当 v1 台账 `xc_knex_migrations` 存在且有记录才执行 `XcMigrationSourcev2` → 全新库 v2 迁移**永不运行**(实测 nocodb-dev:v0 台账 100 条全 batch1、无 v1/v2 台账,即 fresh 安装路径;现有索引系带外手工补入)。后果:全新部署上并发同 title 创建全部越过 service 预检(check-then-insert)成功落库,违背 R1 唯一索引修复的目标。建议:`nc_001_init` dashboards 建表段补 `table.unique(['base_id','title'], 'nc_dashboards_base_title_unique')`(与 v2 迁移同款,fresh/upgrade 双路径一致)。

## int 抽验结果(旁证,非 issue)

- CRUD 42/42 通过:create(trim/order/created_by/owned_by)、校验(空 title/非字符串/256 超长/非字符串 description/重复 title 均 400)、list 缓存路径(appendToList 后新行可见)、update(title/desc=null/同 title 允许/重复 400)、delete 后 get 404 + 重建允许。
- 跨 base 隔离:get/patch/delete 他 base id 全 404,list 互不可见,跨 base 同 title 允许。
- 并发同 title(10 线程):恰 1 个 200,余 400/409,无 500;DB 恰 1 行。
- pg8000 直查 nocodb-dev(未触生产库):行状态/created_by/owned_by/唯一索引 `nc_dashboards_base_title_unique`/迁移文件均在。
- 实跑门:`tsc --noEmit` = 0;`jest baseVariableValidators.Fork.spec` = 12/12。
- 环境干扰记录:会审期间他路 rspack 重启致 dev server 三次掉线、xc-auth JWT 两次失效,已用「等就绪→重登→重试」吸收,非 F10 问题。
