# r6-f05-int-a.md — 第 6 路集成测试（正向+边界）F05 Variables 收敛确认

裁决：**PASS**（5/5 测试项全过，0 error）

环境：dev server 127.0.0.1:8080（未重启未杀）；主测账号 f05r6a@ce-ee.local（signup 成功，org-level-viewer；baseCreate 403 符合预期后回落 f01e2e@ce-ee.local 做 base/variable owner 操作）；DB 实测 nocodb-dev（pg8000 经 Infisical KDL DB_*，host qnap.elf-balance.ts.net，未触碰 nocodb 生产库）。

## 1. create 四轴校验 — PASS

非法输入 14/14 全 400（POST /api/v2/meta/bases/:baseId/variables）：

| 轴 | 用例 | 结果 |
|---|---|---|
| type | "bogus" / 123 / true | 400 ×3 `Variable type must be one of: text, secret` |
| value | 123 / {"a":1} / [1,2] | 400 ×3 `Variable value must be a string` |
| value | 65537 字节（64KB+1） | 400 `Variable value exceeds 64KB limit` |
| description | {"x":1} / 123 / [] | 400 ×3 `Variable description must be a string` |
| key | 缺失 / 123 / "" | 400 ×3 `Variable key is required` |
| key | 256 字符 | 400 `Variable key exceeds 255 characters limit` |

边界合法值 3/3 全 200：value=65536（恰 64KB）200；key=255 大写字符 200；description=null 显式传 200。

## 2. text/secret CRUD 全链路 — PASS

- text（F05_TXT）：create 200 → get 200（hello/d1）→ PATCH value+description 200（world2/d2）→ PATCH value=null 200，value 落 ''（R2 清空语义）。
- secret（F05_SEC）：create 200 → **GET×3 恒定** "s3cret-value-42"（无双解密/缓存污染，R2 cache 修复生效）。
- list 双掩码：list 返回中 F05_SEC 的 value/default_value 均不暴露（JSON null/键缺失）；F05_TXT value 正常返回。
- type 双向切换：F05_TXT text→secret 200 值 "flip-me-77" 保持；secret→text 200 同值；F05_SEC secret→text 200 值 "s3cret-value-42" 保持 → 再 text→secret 200 同值。往返加解密一致。

## 3. key 不可改 / 404 面 / 跨 base 隔离 / 并发 — PASS

- key 改名 PATCH {"key":"RENAMED_KEY"} → 400 `Variable key cannot be changed. Delete and recreate`。
- key 同值+description 同发 → 200（key 视为未变，正常更新）。仅传同值 key 单字段 → 400 `Nothing to update`（设计行为，语义合理）。
- 404 面：get/patch/delete 不存在 variableId → 404 ×3；正确 variableId 配错 baseId 的 get/patch/delete → 404 ×3（getVariableWithBaseCheck 拦截，无跨 base 写入）；不存在 baseId 的 list → 404 `ERR_BASE_NOT_FOUND`。
- 跨 base 隔离：base2 建同 key F05_TXT → 200 合法（key 唯一性按 base 作用域）；base2 list 仅含自身 1 条；base1 的 F05_SEC id 经 base2 get/patch → 404 ×2，base1 数据未受影响。
- 并发同 key：5 并发 POST 同 key，两轮分别 400/400/200/400/400 与 400/200/400/400/400，均 **1 成 4×400**，DB 各仅 1 行（唯一约束兜底正确转 400，无 500）。

## 4. 删 base 零残留 — PASS

- DELETE /api/v2/meta/bases/:id ×4（base1、base2×2、同名孤儿 base）全 200。
- pg8000 实测 nocodb-dev（确认 current_database()='nocodb-dev'）：
  - `nc_base_variables` WHERE base_id IN (4 个已删 base) → **0 行**
  - 全库 `WHERE key IN ('F05_TXT','F05_SEC','CONC_KEY','CONC2_KEY')` → **0 行**
  - `nc_bases_v2` 4 行 deleted=true（平台既有 trash 软删机制，所有 base 删除同路径，非 F05 引入的残留）
- 未创建 source/数据表/schema，无需 DROP。

## 5. editor 降权 403 — PASS（实测+读码双证）

- 读码：`packages/nocodb/src/utils/acl.ts` — baseVariableList/Create/Update/Delete 仅注册于 permissionScopes.base（:268-271）；ProjectRoles.EDITOR include 块无任何 baseVariable*；CREATOR/OWNER 为 exclude 语义块（baseVariable* 不在 exclude → 放行）。继承链 VIEWER→COMMENTER→EDITOR→CREATOR→OWNER 中 EDITOR 及以下拿不到。
- 实测：f05r6a@ce-ee.local 被邀为 base1 editor（invite 200）后，对 /variables 的 list/get/create/update/delete → **403 ×5**（`You do not have permission to perform the action "baseVariableList"...`），owner 复查 list 无 editor 尝试写入的任何行。

## 备注（非 error）

- 会话中 token 两次失效（401 Invalid token），重登录后恢复：dev server rspack 重启轮换 JWT secret 所致，测试基建现象，非 F05 缺陷。
- 资源清理已完成：4 个 f05r6a* base 已删、变量行 0 残留、editor 邀请随 base 删除消除。
