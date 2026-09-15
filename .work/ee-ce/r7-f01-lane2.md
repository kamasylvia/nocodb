# r7-f01-lane2 (第 7 轮收敛确认 · 独立第 2 路)

## int — PASS

实测环境:dev server 127.0.0.1:8080(未重启),账号 f01e2e@ce-ee.local 回落(f06r7b@ce-ee.local 可登录但无 baseCreate 权限,org-level-viewer)。资源 f06r7b_base / f06r7b_t1(含 unique 列 Code),测完 base 已删(trash)。

1. bulk 批内重复/撞已存:`POST /api/v2/tables/{id}/records` 批内双 `BULK1` → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION(value='BULK1');批含已存 `EXIST` → 400(value='EXIST');where 回查 `BULK`/`B` 均 0 行 → 整批回滚 0 落库。
2. 更新撞值:PATCH 对象形态 `{Id:1,Code:"EXIST"}` 与数组形态 `[{Id:1,Code:"EXIST"}]` → 均 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION(fieldName=Code,value=EXIST);自值 PATCH → 200;置 null → 200(null 后重插原值成功)。
3. 并发:5 并发同值 POST → 恰 1×200 + 4×400,落库恰 1 行;`?undo=true` 首插成功、重复仍 400,不绕约束。
4. 列改名:title 与 column_name 均改(Code→SerialCode)后 DB 索引保留(`f06r7b_t1_Code_key` ON "SerialCode",pg RENAME 自动跟随),插入/PATCH 撞值仍 400 且 **fieldName 跟新 title='SerialCode'**;新建 unique 列 TempU 索引 `uk_…` 在,删列后索引消失(pg_indexes grep 无命中)。
5. 非法输入矩阵:建列 unique=1 → 400 "The unique flag must be a boolean value";unique='false'/'yes' → 400(ajv);建表 unique='true' → 400(ajv oneOf),坏表未建成;PATCH unique='false' → 400,合法 false→true 切换正常;NULL 多行放行;Number 列 unique 重复 → 400(value='42');空串重复(批内+撞已存)→ 400 value='' 正确回显。

## rev — issues

- packages/nocodb/src/helpers/uniqueConstraintErrorHandler.ts:310-313(同型 644-648、875-878):PG 23505 detail `Key (col)=(v)` 的 value 正则 `([^)]+)\)` 在值本身含 `)` 时截断,错误回显 value 不精确(实测:插 `Code="a)b"` 重复 → `value:'a'`,应为 `a)b`;error 类/fieldName/整批回滚均正确,仅回显字段错误):建议 value 提取失败或可疑时沿 R3 模式优先回显 payload 原值(如对 detail 中括号值做平衡/贪婪匹配,或 value 含截断痕迹时用 `insertData[column.column_name]` 覆盖)。

rev 其余检查项无 API 可达链问题:三 catch 接线(updateByPk 2900 / bulkUpdate 4642 / bulkUpdateAll 4821)映射、insert.ts 两 catch、23505 结构化检测、PK pass-through(`_pkey`/`PRIMARY`/`<tbl>.PRIMARY`)、bulkUpdate 仅取 `datas[0]` 作 payload 猜测(pg detail 常在,不可达)。非 diff 观察(不判 issue):tableCreate 内联 unique 索引为非 partial、addColumn 路径为 `WHERE __nc_deleted` partial,软删行占值语义不一致系上游 CE 行为;handler 内导出的 `isUniqueViolation` 与 `~/helpers/isUniqueViolation.ts` 重名且无消费者(死代码,无 API 链)。

rev 实跑门:tsc --noEmit(packages/nocodb)= 0;jest uniqueConstraintHelpers = 14/14 PASS。

## 备注

- f06r7b@ce-ee.local 本轮 signup,无 admin 删用户路由可用,账号残留(无任何 base/资源,org-level-viewer);资源 f06r7b_base(×2,含括号值补测临时 base)已删。库中另见 `f06r7b2_base` 为历史轮资源,非本轮,未动。
