# r6-f01-lane2 (int + rev) — 2026-09-12

## 裁决

**PASS**

## rev 实跑门

- `npx tsc --noEmit`(packages/nocodb)→ EXIT=0
- `npx jest uniqueConstraintHelpers` → 14/14 passed, EXIT=0

## int 实测(账号 f06r2a 登录 403 No Access 无 base 权限,回落 f01e2e;资源前缀 f06r2a_,base 已删)

1. **bulk 批内重复/撞已存 → 400 整批回滚**:POST records 数组 `[{Code:b1},{Code:b1}]` → 400 `FIELD_UNIQUE_CONSTRAINT_VIOLATION` (fieldName=Code, value=b1),回查 b1 落库 0 行;`[{Code:b2},{Code:a1}]`(撞已存)→ 400 value=a1,b2 落库 0 行。
2. **更新撞值两形态 + 放行**:PATCH 对象 `{Id:r1,Code:a2}` 与数组 `[{Id:r1,Code:a2}]` 均 400 fieldName=Code value=a2;自值 PATCH `{Id:r1,Code:a1}` 200;PATCH null 200,双行 null 共存 200;失败 PATCH 后 r1 值未被污染。
3. **并发 + undo**:5 并发同值插 → statuses [400,400,400,400,200],恰 1 成,DB 行数 1,错误全为 FIELD_UNIQUE_CONSTRAINT_VIOLATION;`?undo=true` 撞已存 → 400 不绕约束;`?undo=true` 正常插 200。
4. **列改名/fieldName/DB 索引**:PATCH column title Code→Serial 200,meta unique=true 保持,DB 索引 `f06r2a_t1_Code_key`(schemaname=pxmjmr595b663mr)存在;改名后撞值错误 `Serial field unique constraint violation`(fieldName 跟新 title);DELETE column 200 后 pg_indexes 仅剩 deleted_idx/order_idx/pkey,Code 列消失(经 pg8000 查 nocodb-dev,host qnap.elf-balance.ts.net,未触生产库)。
5. **非法输入矩阵 + 空串**:tableCreate unique='false'/'yes'/1 及 LongText+unique → 全 400,表未建;columnAdd unique='false'/0/LongText+unique → 全 400;columnUpdate `{unique:'true'}` → 400 且 Title 列 unique 未翻转;空串首插 200,二次插 → 400 `Value '' already exists`(空串回显,R3 fix 生效),落库仅 1 行。

## rev 复审(uniqueConstraintErrorHandler.ts 全文 + BaseModelSqlv2.ts 三 catch)

- 三 catch 接线正确:updateByPk(:2896-2907 handle→errorUpdate→rethrow)、bulkUpdate(:4639-4648 rollback→handle→rethrow)、bulkUpdateAll(:4819-4827 handle→rethrow);handler throw 时原错不外泄,经 exception-mapper.ts:98-124 转 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION。
- 23505 结构化检测(:230-245)、_pkey 直通(:293-306,:628-641)、MySQL 'PRIMARY'/'.PRIMARY' 直通(:776-778)、空串 payload 回退(:318-324)逻辑正确;handler 内 DB 回查用连接级驱动在 bulkUpdate rollback 之后执行,对撞值语义无影响(已存行不属回滚范围)。
- insert 路径不经 handler,由 pre-check + mapper 兜底;int-1/int-3(含并发竞态窗口与 undo)实测错误映射全正确,无漏接线。
- handler export 的 `isUniqueViolation` 在 src 内无调用者(base-variables.service 用的是独立 helpers/isUniqueViolation.ts,F05 域),无风险面。
- 无 API 可达链的洞。

## 备注(非 issue)

- f06r2a 账号 org-level-viewer 无 baseCreate 权限,回落 f01e2e(任务指定回落路径)。
- f06r2a_base 删除为上游软删语义,物理 schema 表随 trash GC 周期清理,与历史各 lane 测试 base 残留一致,非 F01 验收链。
- 中途两次 401 为同名回落账号被并行 lane 重复 signin 顶掉 token_version,脚本改为每次运行现登录后复现消失,非被测代码问题。
