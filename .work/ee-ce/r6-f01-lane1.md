# r6-f01-lane1（会审第 1 路：int + rev）

裁决：**PASS**

对象：commit 744d31618b（F01 Unique values only）。工作树 F07 改动未混入（rev 基于 commit diff；F01 三核心文件未被 F07 工作树改动，dev server 运行态可代表 F01）。
隔离声明：未读 .work/ee-ce/ 下任何 r*.md；只读 TASK.md、AGENTS.md、源码、运行系统。

## int（全实测，dev server 127.0.0.1:8080，f06r1a 账号仅 org-level-viewer 403，回落 f01e2e@ce-ee.local；资源前缀 f06r1a_，测完已删）

### T1 11 支持类型建表 unique:true → meta + PG 索引
- table `f06r1a_types`（base `pt5igu7t9oetow6`，pg is_local source）：SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time 各 unique:true → meta 全部 unique=true。
- PG nocodb-dev（schema `pt5igu7t9oetow6`，严禁生产库未触碰）：11 个 `<table>_<col>_key` UNIQUE btree 索引 + `f06r1a_uuid_key`，12/12 齐全。

### T2 不支持类型 / richMode → 400
- columnAdd 400 x9：LongText（plain）、LongText+meta.richMode=true、Checkbox、SingleSelect、MultiSelect、Attachment、JSON、Geometry、User。
- tableCreate 400：LongText+richMode、Checkbox。

### T3 cdf 互斥双向 + 布尔归一
- columnAdd {unique:true, cdf} → 400（"Cannot enable unique constraint because a default value is set"）
- tableCreate {unique:true, cdf} → 400
- columnUpdate 双向：cdf 列 PATCH unique:true → 400；unique 列 PATCH cdf → 400（"Default values are not allowed for unique fields"）
- 布尔归一：columnAdd unique:"false"/"yes" → 400（schema 层）、unique:1 → 400（"The unique flag must be a boolean value"）；tableCreate unique:"false" → 400；columnUpdate unique:"false"/unique:1 → 400（专门文案）；对照 unique:false(boolean) → 200 放行。

### T4 UUID 例外
- tableCreate UUID（不带 unique/readonly）→ 强制 unique=true + readonly=true + cdf=gen_random_uuid()
- columnAdd UUID {unique:false} → 仍强制 true+readonly
- PATCH UUID {unique:false} → 落库仍 true；PATCH {readonly:false} → 落库仍 true（回读 meta 验证）
- UUID 传值插入 → 400（"is readonly column and cannot be updated"）；自动生成两行值互异。

### T5 值判重（f06r1a_dup / f06r1a_num）
- NULL 多行 x2 → 200/200
- 大小写 "Abc"/"abc" → 200/200（区分大小写共存）
- 重复插 "Abc" → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION，fieldName/value 正确
- 空串 x2 → 第二个 400，value=''（payload 回填生效）
- 数值等价 1 vs 1.0 → 第二个 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION
- 批量撞 [bat1,bat2,bat1] → 400，事务回滚无残留（bat1/bat2 = 0 行）
- 并发 5 同 key → 1 成 4 拒（200 x1 + 400 x4，DB count=1）
- 更新撞（PATCH Id:4 abc→Abc，Abc 被 Id:3 占）→ 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION；同值更新自身 → 200
- bulkUpdate 数组撞 → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION
- 软删行释放值：删 abc 行后重插 abc → 200

### 索引生命周期
- enable → PG 建 `uk_<base>_<colId>` partial 索引；disable → 索引删除（PG 实测双向）。

## rev（commit 744d31618b：uniqueConstraintHelpers.ts / columns.service.ts unique 分支 / tables.service.ts UUID 强制门）

逻辑洞：**无**（有 API 可达链的洞未发现）。

- normalizeUniqueConstraintFlag：undefined/null 透传、boolean 透传、其余 400；三入口（columnAdd ~4044 / columnUpdate ~1328 / tableCreate ~1165）均前置调用，无绕过路径。
- validateUniqueConstraint：external source / sqlite / 类型白名单 / richMode / cdf 互斥（UUID 豁免）逐层 400；columnUpdate 的 cdf 反向拦截独立兜底。
- UUID 三层强制门（columnAdd isNcDbSource 强制 + tableCreate 强制 + columnUpdate 不可逆 PATCH）闭环；实测可逆性攻击（unique:false / readonly:false）均被强制回 true；external source 不写约束与 internal_meta（静态审一致）。
- 洞候选实测全部闭合（columnUpdate 预检为 DB 级判等，duplicate-detection.service count 查询）：
  - 存量 1 与 1.0 → PATCH unique:true → 400 "Found 1 duplicate values"（预检不漏放，DB ALTER 不会收到裸 23505）
  - 存量 '' x2 → 400（空串组计入）
  - 存量 Abc/abc + dup x2 → 400（dup 组计入）
- updateByPk/bulkUpdate/bulkUpdateAll 的 handleUniqueConstraintError 挂载点与 insert 路径一致，实测映射生效。
- MysqlClient 去除无条件 DROP INDEX（静态审）：两调用点仅在旧列非 unique 时可达，删除正确；无 MySQL 环境未实测。
- error handler PK 透传（`_pkey` / `PRIMARY` / `.PRIMARY`）与空串 value 回填逻辑与实测行为一致。

### rev 实跑门
- `cd packages/nocodb && npx tsc --noEmit` → exit 0
- `npx jest uniqueConstraintHelpers --runInBand --forceExit` → 14/14
- `cd packages/nc-gui && npx vitest run test/unique-constraint-helpers.test.ts` → 8/8

### 观察（非 error，无 API 可达危害链，不改裁决）
1. columnAdd 传 unique 字符串（"false"/"yes"）被 JSON schema 先拦，错误 message 是误导性的 uidt anyOf 文案（非专门布尔文案，数字 1 才命中专门文案）；400 结果正确，仅信息可读性。
2. 索引形态不一致：tableCreate 路径 DDL 内联 `_key` 非 partial；columnAdd 路径 `uk_` partial（WHERE __nc_deleted）。因软删置空 unique 列值（实测重插通过），非 partial 亦无正确性问题，仅形态差异。
3. 环境噪音：本轮 dev server 被其它进程重启多次（rspack 重编译），测试分段重试完成；f01e2e 为 5 路共用账号，signin 互顶 token_version（脚本带 401 重登重试）。注：本文件在我写入前已被一同名 lane1 实例于 22:11 写过一版，本版为该 lane 指派实例的最终覆盖版。

## 清理
本轮资源已全部删除：tables f06r1a_types/f06r1a_dup/f06r1a_num/f06r1a_conv/f06r1a_empty + base f06r1a_probe（均 200）。旧轮遗留（schema pust0d0d6mcjpm5/p493wanpvw1oey8 下 f06r1a_* 表）非本轮产物，未触碰。
