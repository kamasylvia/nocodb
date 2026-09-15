# r2-f01-rev-a — 前端+改动面代码复审(第 3 路,第 2 轮)

## PASS

核对记录(实测,非轻信):

- 逐 hunk:全部改动处带 `[CE-EE]` 标记;无语法/类型错误。测试实测:后端 jest 13/13 过、前端 vitest 8/8 过。
- EditOrAdd.vue:1512 `!blockUnique` 保留 `isXcdbBase` 前置,与后端 external 拒绝语义一致;1551 PaymentUpgradeBadge `blockUnique && !unique` 随 gate 自动隐藏;`showEEFeatures` 在 273/275/291/294 仍有消费,无死变量。
- normalizeUniqueConstraintFlag 三接入点:
  - columnAdd:originalUnique(4028)先存后归一(4033),唯一消费点 4763 为真值判断,非布尔值在 4033 已抛 → 真值恒等,无时序错位。
  - columnUpdate:归一化后 undefined(null)经 updateMetaAndDatabase:692「undefined → 保留现存值」= no-change,与 jsdoc 一致;false 走 drop。下游 1317/1340/1369/1464 及 updateMetaAndDatabase 全部消费归一化值,无绕过。`as any` 仅类型层面,无害。
  - tableCreate:map 内 `ck: originalUnique ? 1 : props.ck||0` 在归一化前算,但非布尔 originalUnique 会在 validate 循环(1151)先抛 → 无「ck=1 但 unique=false」不一致窗口;grep 确认 tables.service 无第二 unique 消费点。
- UUID gate:external 源 `colBody.unique = !!colBody.unique`(已归一布尔);PgClient change===1 走 addUniqueConstraintToQuery(内部 `!n.unique` 早退);readonly=true 强制与 unique 无耦合;UUID 在 sdk UNIQUE_CONSTRAINT_SUPPORTED_TYPES,显式 unique=true 顶部 validate 已覆盖。NC-DB 强制 true 与上游一致。CE 无 mssql sql client 属上游既有缺口,非本 diff 引入。
- MysqlClient:两个 call site(change===1 新列、change===2 仅 nIsUnique!==oIsUnique)均满足「旧索引不存在」前提;同列保持 unique(改名)时 nIsUnique===oIsUnique 完全跳过,MySQL 唯一索引随列,无残留;storeUniqueConstraintName 不覆盖已有名。
- BaseModelSqlv2:update(2900)/bulkUpdate(4642)调用模式与 insert.ts:234/699 完全一致;errorUpdate 是 no-op stub,跳过无影响;非唯一错误 handler return 后原样 throw。UniqueConstraintViolationError 与 insert 路径同一类,全局 filter 映射一致。
- 单测:后端 13 断言、前端 8 断言逐条与实现/-sdk 清单吻合(错误正则、cdf 空串豁免、LongText/Attachment 排除)。jest.config isolatedModules:true 是 ts-jest 29.2.5 合法选项,type-check 留给 rspack/tsc 与仓构建结构一致;Fork 桶与仓 AGENTS.md §3 约定一致。
- 卫生:git status 无 packages/nocodb-sdk/src/lib/Api.ts;.gitignore 改动带 [CE-EE] 且内容合理(.work/、noco-integrations shim)。
