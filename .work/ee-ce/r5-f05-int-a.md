# r5-f05-int-a — F05 Variables 第 5 轮收敛确认（集成测试：正向+边界）

后端 http://127.0.0.1:8080（dev, nocodb-dev）；专用账号 f05r5a@ce-ee.local（base creator）；admin f01e2e（仅建 base/邀请）；editor 账号 f05r5a-ed。base phjjyix5pbhz8vb + base2 pc5pgu5en8k79t2，测毕已删，孤儿 schema 已手动 DROP。

## 裁决：PASS（0 error）

### 1. create description 校验（R4 修复验证）— PASS
- `description:{"a":1}` → HTTP 400 `"Variable description must be a string"`（实测）
- `description:123` → HTTP 400 同上（实测）
- `description:"hello desc"` → HTTP 200，响应 `description="hello desc"`（实测）
- `description:null` → HTTP 200，响应 `description=null`（实测）
- update 侧同契约（超任务范围补充）：PATCH `description:{"x":1}` → 400；PATCH `description:"newdesc"` → 200 生效（实测）
- 源码依据：`packages/nocodb/src/services/base-variables.service.ts:50-58`

### 2. create type 白名单回归 — PASS
- `type:"bogus"` → HTTP 400 `"Variable type must be one of: text, secret"`（非 500，实测）
- `type:123` → HTTP 400 同上（非 500，实测）
- `type:"text"` / `type:"secret"` → 200（实测）
- 源码依据：`packages/nocodb/src/helpers/baseVariableValidators.ts:40-51`

### 3. text/secret CRUD 全链路 + 掩码 — PASS
- text：create → PATCH value → PATCH description → DELETE → 再 GET 404 `"Variable not found"`，全链路 200/404 正确（实测）
- secret create：value 响应回显明文 `super-secret-9137`（单变量 get 契约）；`default_value` 注入被拒（响应恒 null，service create 不收该字段，`base-variables.service.ts:67-73` 显式构建 payload）
- secret GET×3：三次均 `'super-secret-9137'`，恒定无衰减（R2 双重解密修复生效，实测）
- secret PATCH value 轮换 → GET×2 恒定 `'rotated-secret-42'`（实测）
- type 翻转 text↔secret：value `'x'` 双向保活（重加密/解密往返正确，实测）
- list 双掩码：secret 行 `value` 键缺失、`default_value` 键缺失（JSON 序列化后无该键）；text 行 value 正常显示。UI 掩码契约符合（实测，5 行逐一断言）
- 落库密文：`I3_SECRET` 行 value = `U2FsdGVkX19V...`（CryptoJS 密文），无明文残留（pg8000 实查 nocodb-dev）

### 4. 校验矩阵 / key 不可改 / 404 面 / 跨 base 隔离 — PASS
- key 缺失 → 400 `Variable key is required`
- key `abc_lower` / `1ABC` / `A-B` → 400 `UPPER_SNAKE_CASE`（模型 KEY_REGEX）
- key 256 字符 → 400 `exceeds 255 characters limit`；key 255 字符（边界）→ 200
- value `123` / `{"a":1}` → 400 `must be a string`
- value 65537 字符 → 400 `exceeds 64KB limit`；value 65536 字符（边界）→ 200
- PATCH 改 key → 400 `"Variable key cannot be changed. Delete and recreate"`；PATCH 同名 key + value → 200 正常更新；PATCH 空体 → 400 `Nothing to update`
- 404 面：GET/PATCH/DELETE 未知 variableId → 全部 404（无 500）
- 跨 base：base2 变量经 base1 URL → 404（base_id 不匹配）；base1 变量经 base2 URL（无权限 base）→ 403 ACL 拦截；PATCH/DELETE 劫持尝试 → 403；双向 list 互不泄漏；目标变量 PATCH 后值完好（`v2` 未被篡改）

### 5. 并发同 key + 删 base 零残留 — PASS
- 5 并发 POST `CONC_KEY`：响应码 `400 400 400 200 400` — 恰好 1 成功 4×400；4 条 400 报文一致 `"Variable key CONC_KEY already exists in this base"`（unique violation 兜底生效，`base-variables.service.ts:74-81`）；list 中该 key 恰 1 行（实测）
- 删 base（×2）后 pg8000 实查 nocodb-dev：`nc_base_variables WHERE base_id IN (base1,base2)` = **0 行**（含密文 secret，F05 R1 修复点 `Base.softDelete` → `BaseVariable.deleteByBaseId`，`src/models/Base.ts:698-700`）
- 孤儿 schema：base 删除后 schema 空壳残留（0 表）为 base 级既有行为（PROJECT_DELETE/SOURCE_DELETE handler 均 no-op，全库 ~50 个历史 p-schema 同状态），非 F05 引入；本轮两个 schema 已按任务书手动 DROP，复查 `[]`

### 6. 权限 editor 降权 — PASS（实测）
- f05r5a-ed 邀为 base editor 后实测 5 路：LIST / CREATE / PATCH / DELETE / GET single → 全部 HTTP 403，报文含对应权限名（`baseVariableList/Create/Update/Delete`）
- 读码佐证：`baseVariable*` 仅入 `permissionScopes.base`（`src/utils/acl.ts:267-271`），不在 viewer/commenter/editor 任一 include 集（`acl.ts:337-626` 继承链），仅 creator/owner（exclude 型）与 super admin 放行；实测与读码一致
- creator 对照组同刻 GET 正常（未误伤）

## 备注（非 error）
- f01e2e 共享回落账号的 JWT 频繁失效（signin 互踢 token_version），与并行复审路共用有关；测试侧已用原子 signin+操作规避，不影响被测系统
- 测试临时目录（含 token/DB 凭证文件）已删除

结论：6/6 PASS，0 error。
