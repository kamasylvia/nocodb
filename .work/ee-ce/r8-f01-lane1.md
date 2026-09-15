# r8-f01-lane1 — F01 Unique values only 第 8 轮收敛确认（int + rev）

对象：commit 744d31618b。dev server 127.0.0.1:8080（未重启）。实测账号 f01e2e@ce-ee.local（专用号 f06r8a 建号成功但 org-viewer 无 workspace 角色，baseCreate ACL `scope:'workspace'` → 403，API 全走 f01e2e；已实测 f01e2e PATCH /api/v1/users/{id} 提 f06r8a 为 org-level-creator 后仍 403，缺 workspace 成员资格）。

## int：53 检查点，全部实测通过（3 个初 fail 均为脚本缺陷，修正重测通过）

### 1. 11 支持类型 meta + PG 索引 — PASS
- tableCreate `f06r8a_types` 11 列（SingleLineText/Email/PhoneNumber/URL/Number/Decimal/Currency/Percent/Date/DateTime/Time）unique:true → 全部 200，meta `unique:true` 11/11。
- pg8000 查 nocodb-dev（qnap.elf-balance.ts.net:5432，未触生产库）：per-base schema 内 11 列各有 `<tbl>_<col>_key` UNIQUE 索引 11/11；UUID 列（未显式传 unique）另有 `uid_col_key` UNIQUE。
- UUID 例外：tableCreate/columnAdd 不传 unique → meta `unique:true, readonly:true`；PATCH {unique:false} 后 meta 仍 true（b21/b22）。

### 2. 400 边界 — PASS
- LongText unique:true → 400；LongText richMode+unique → 400；Checkbox unique → 400（columnAdd 与 tableCreate 双路径）。
- cdf 互斥双向：① unique+cdf 同提交 → 400（b4/b11）；② unique 列 PATCH 设 cdf → 400（b8）；③ 已有 cdf 列 PATCH 开 unique → 400（b20 重测 400）。
- UUID 例外（允许 unique 与 cdf/自动生成共存）按设计强制，见上。

### 3. 值判重 — PASS
- NULL 多行：同 unique 列插两行 NULL → 均 200。
- 数值等价：Decimal 1.5 后插 1.50 → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（value 报 '1.5'）。
- 大小写：'Abc' 与 'abc' 并存成功（PG 索引大小写敏感；enable-unique 预检 `checkForDuplicates` 亦精确匹配，两者一致）。
- 重复插 → 400 + `FIELD_UNIQUE_CONSTRAINT_VIOLATION`（fieldName/value 正确）。
- 批量撞（数组 2 行同值）→ 400 + code。
- 并发同 key 5 线程 → 恰 1×200 / 4×400，全部带 code。
- 更新撞：集合级 PATCH {Id, st:'Abc'} → 400 + code（重测通过）；自更新同值 → 200；bulk 数组 PATCH 撞值 → 400 + code。

### 4. 布尔归一 — PASS
- columnAdd unique:"false"/"yes"/1 → 400；columnUpdate unique:"false" → 400；tableCreate unique:"false" → 400。注："false"/"yes"（字符串）在 swagger payload 校验层先拒（消息为 schema 校验），`1`（数字）到达 `normalizeUniqueConstraintFlag` 报 "The unique flag must be a boolean value"；行为均 400，符合要求。

### 附带行为观察（实测，非 error）
- 唯一索引两种形态：tableCreate 路径 → 全局 UNIQUE constraint；columnAdd/columnUpdate-enable 路径 → partial unique（`WHERE __nc_deleted IS NULL OR false`）。实测 v2 行级 DELETE 为物理删除（PG 查证行已不在），`__nc_deleted` 恒 NULL，两形态当前无 API 可达的行为差异。
- 运维噪音（非 fork 代码问题）：f01e2e 为共享回落账号，单会话强制（`setRefreshToken` 轮换 token_version）使并行各路 signin 互踢 JWT，本轮多次 401 均由此，重签即恢复。
- 测后清理：3 个测试 base（f06r8a_base / f06r8a_rt / f06r8a_pgcheck）均已 DELETE（soft delete 进 trash，平台统一语义）。

## rev：三文件逻辑洞审查

实跑门全绿：`npx tsc --noEmit` exit 0；`npx jest uniqueConstraintHelpers --runInBand --forceExit` 14/14；`nc-gui vitest unique-constraint-helpers.test.ts` 8/8。

**columns.service.ts unique 分支 / tables.service.ts UUID 强制门 / uniqueConstraintHelpers.ts：无 API 可达的逻辑洞。** 逐项核验：
- `validateUniqueConstraint` 的 external-source 检查在 `source` 为空时跳过，但三个调用点（columnAdd/columnUpdate/tableCreate）source 均非空，无绕过链。
- columnUpdate 对 UUID（含转成 UUID 的列）强制 unique+readonly 在 normalize 之前，PATCH {unique:false} 静默转 true 为 commit 声明的意图行为（防 user-supplied-UUID 洞），非缺陷。
- enable-unique 路径先 validateUniqueConstraint 再 `checkForDuplicates`（排除软删行），实测有值列关→开约束正常、有重复时 400。
- `normalizeValueForUniqueCheck` 仅被 duplicate-detection.service 的 `validateUniqueValue` 引用，而该方法自注 "not used anywhere"；在用的 `checkForDuplicates` 用精确匹配，与 PG 索引大小写敏感语义一致，无"预检放行/运行时拒绝"分裂。
- observation（非洞）：tables.service UUID 强制循环先于 normalize 执行，tableCreate 对 UUID 列传 `unique:"false"` 会被强制 true 后通过（无 400），与非 UUID 列同输入 400 的行为不一致；因 unique/readonly 无论输入都被强制，无约束绕过或一致性问题。

## 裁决

int PASS + rev PASS（无 API 可达逻辑洞）→ **本轮 lane1 总裁决：PASS（0 error）**。
