# r2-f01-int-b.md — F01 Unique 第 2 轮会审 · 集成测试-对抗面（第 2 路）

环境：dev server 127.0.0.1:8080 / nocodb-dev（pg18@qnap.elf-balance.ts.net:5432，pg_indexes 实查）。资源前缀 f01r2b_，测完已删。

## PASS

- T1 bulk 插入整批回滚 — PASS
  - 批内重复 `[{"Name":"ddd"},{"Name":"ddd"}]` → HTTP 400 `{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","fieldName":"Name","value":"ddd"}`；count 保持 3，ddd 0 落库。
  - 撞已存 `[{"Name":"eee"},{"Name":"aaa"}]` → 400 FIELD_UNIQUE（value 'aaa'）；count 保持 3，eee 0 落库。
  - 单条 control `{"Name":"aaa"}` → 400 同错误。
  - 混合批更新 `[{"Id":2,"Name":"aaa"},{"Id":3,"Name":"zzz_ok"}]` → 400 FIELD_UNIQUE，zzz_ok 未落库（整批回滚）。
- T2 更新撞值两形态 + 自值 + null — PASS
  - 对象形态 PATCH `{"Id":2,"Name":"aaa"}` → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION。
  - 数组形态 PATCH `[{"Id":2,"Name":"aaa"}]` → 400 FIELD_UNIQUE_CONSTRAINT_VIOLATION。
  - 自值更新 `{"Id":2,"Name":"bbb"}` → 200 放行。
  - null 覆盖 `{"Id":2,"Name":null}` → 200 放行（PG 多 NULL 不占约束），回写 bbb 成功。
- T3 并发 — PASS
  - 5 curl 并发插入同值 `race_x1` → 恰 1×200（Id 9），4×400 FIELD_UNIQUE；`where=(Name,eq,race_x1)` 查询恰 1 行。
- T4 undo / GET / move — PASS
  - `?undo=true` 插入 dup `aaa` → 400 FIELD_UNIQUE（undo 不绕约束）；`?undo=true` 新值 → 200。
  - GET `/records/1` → 200；GET `/records/999` → 404（正常）。
  - POST `/records/1/move` → 201 true；`{"undo":true}` 恢复 → 201 true，行回列表。
- T5 布尔归一回归面 — PASS
  - 建列 unique:true（POST columns）→ unique=true + internal_meta.unique_constraint_name=uk_p2ku…；dup 写入 → 400，约束生效。
  - PATCH unique:false → unique=false；dup 值写入 2 行均 200；pg_indexes 确认 uk_* 索引已删（约束真关）。
  - PATCH unique:null → 归一为 false（关掉）；dup 值写入 2 行均 200。判定：**合理**（显式 null 按 falsy 关闭处理，与 unique:false 等价；实测无「静默维持开启」的歧义状态）。
  - 存量重复时 PATCH unique:true → 400 "Found 1 duplicate values…"（启用前重复防护，合理）；清除重复后恢复 true 成功，uk_* 索引重建（partial index `WHERE __nc_deleted IS NULL OR false`，与软删除排除逻辑一致）。
  - 观察（非缺陷）：unique:false 后 internal_meta.unique_constraint_name 残留旧名；重建时无命名冲突，仅元数据缓存。
- T6 改名/删列 — PASS
  - PATCH title `Code`→`Code_R2`（body 不带 unique 键）→ DB `uk_p2ku31qoyh3fo3v_mo2a6ayv0aq5jvj_cjnrsc2q1rormjt` 索引保持（pg_indexes 实查）；随后 dup → 400 且 `fieldName":"Code_R2"`、message 均跟随新 title。
  - 改名后旧 title 别名 `{"Code":"REN_V"}` PATCH → 200 但目标行值未变（旧 title 被静默忽略）——改名后字段别名失效属 NocoDB title 语义，非约束缺陷。
  - DELETE 列 → pg_indexes 复查 uk_* 消失，仅剩 Name_key/pkey/order_idx/deleted_idx。
- T7 长文本/边界 — PASS
  - 260 字符 'L'*260 同值冲突 → 400，message/value 完整 260 字符，无截断无崩溃。
  - emoji 判重：update 路径 `🚀😀emoji` 与 insert 路径 `🌈dup` 均正确 400 FIELD_UNIQUE 且 value 完整。
  - `AAA` 与 `aaa` 共存 → 200（PG text 大小写敏感语义正确）。
- T8 读码复核（更新族 catch 覆盖）— PASS
  - `packages/nocodb/src/db/BaseModelSqlv2.ts:2900` updateByPk catch → handleUniqueConstraintError（insertData=data）。
  - `BaseModelSqlv2.ts:4642` bulkUpdate catch → handleUniqueConstraintError（insertData=datas[0]）。
  - `db/BaseModelSqlv2/insert.ts:234`（单条）/`:699`（bulk）已接 handler。
  - `bulkUpdateAll` catch（BaseModelSqlv2.ts:4819 `catch (e) { throw e; }`）无 unique 映射，但调用方仅 `services/columns.service.ts:2539/2761/2871`（select option 重写内部操作），无 v2 数据 API 面；`updateLTARCols` 仅触 LTAR link 表不涉本表 unique 列。按 TASK「只报有实际 API 面暴露的」→ 无 issue。

## 结论

8/8 项 PASS，0 error。
