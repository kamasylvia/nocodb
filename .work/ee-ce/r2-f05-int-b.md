# r2-f05-int-b.md — F05 第 2 轮会审 · 集成测试-对抗面（第 2 路独立报告）

- 日期：2026-09-12
- 后端：http://127.0.0.1:8080（dev，nocodb-dev，进程带 NC_CONNECTION_ENCRYPT_KEY）
- 方法：全 API 实测（curl）+ uv/pg8000 直查 nocodb-dev `nc_base_variables`（严禁生产库，实测 current_database()=nocodb-dev）
- 资源：base 前缀 `f05r2b_`（已全部软删 + 孤儿变量行已清）；测试账号 f05r2b@ce-ee.local（本路专用，见「环境事件」）保留供复测

## 逐项判定

### 1. secret 密文落库 — PASS
- create `{"key":"SECRET_A","value":"plain-A-value","type":"secret"}` → 200
- DB 直查：`value` = `U2FsdGVkX1+4pN7Z6bffySB+6vz5p0HU1/ojp3mq...`（44 字符，CryptoJS/OpenSSL salted 密文形态），非明文
- 交叉验证：`ps eww` 取 dev server 进程 env 内 `NC_CONNECTION_ENCRYPT_KEY`，本地 crypto-js 解密该密文 → `plain-A-value`（密文与进程 key 一致、可逆正确）

### 2. 加密状态机 text→secret→改值→text — PASS
SM2_VAR 四步逐步抓 DB + API（掩码）：

| 步骤 | API 读值 | DB 形态 |
|---|---|---|
| create text "alpha2" | alpha2 | text / 明文 alpha2 |
| PATCH {"type":"secret"} 200 | alpha2（解密读回正确） | secret / 密文 U2FsdGVkX193WZuH…（44）；list 中 value 掩码 ABSENT |
| PATCH {"value":"beta2"} 200 | beta2 | secret / **新**密文 U2FsdGVkX1/zXz7r9of…（≠step2 密文，重加密正确） |
| PATCH {"type":"text"} 200 | beta2 | text / 明文 beta2；list 明文可见 |

### 3. 非法输入矩阵 — PASS（全部 400 或明确语义）

| 输入 | 结果 |
|---|---|
| type:"weird" | 400 `Variable type must be one of: text, secret` |
| type:"Secret" | 400 同上（大小写敏感，无法借道绕过加密） |
| type:1 | 200 → 落库 type=text（回落默认，DB 无异常行） |
| type:null | 200 → 落库 type=text（等价于不传） |
| value:{"x":1} | 400 `Variable value must be a string` |
| value:42 | 400 `Variable value must be a string` |
| value 65537 字符 | 400 `Variable value exceeds 64KB limit` |
| key 300 字符 | 400 `Variable key exceeds 255 characters limit` |
| key "MY VAR" / 中文 / 小写 / 数字开头 | 400 `Variable key must be UPPER_SNAKE_CASE…` |
| key 重名 | 400 `Variable key SECRET_A already exists in this base` |
| PATCH {} | 400 `Nothing to update` |
| PATCH {"key":同值} | 400 `Nothing to update` |
| PATCH {"key":改值} | 400 `Variable key cannot be changed. Delete and recreate` |

判定注记（非 error）：`type:1` / `type:null` 回落默认 text 而非 400——语义一致明确（与省略 type 等价），落库形态正确，无安全问题；记录供裁决方知悉。

### 4. 修复回归（有 key 环境全 200；default_value 不泄露）— PASS
- 当前进程 secret create / get / patch / list 全 200
- create body 注入 `default_value:"LEAK_SECRET", order:999, base_id:"INJECT", is_overridden/is_inherited/inheritance` → 200；响应与 DB：default_value ABSENT、base_id 保持真实值、order 自增、is_overridden=false（显式构造 payload 防注入生效）
- PATCH 带 `default_value:"PATCH_LEAK"` → 200 且仍 ABSENT（被忽略）
- list 全量 12 行 `rows_with_default_value=0`

### 5. order 注入 — PASS
- create 带 `order:999` → 结果 order=5（用户值被忽略，服务端自增）；后续 ORD_1=6、ORD_2=7 严格递增

### 6. 并发同 key 5 路 — PASS
- 5 路并发 POST 同 key：**1×200 + 4×400**（两轮复验，RACE_KEY 与 RACE_KEY2 各）
- 400 body = `Variable key RACE_KEY2 already exists in this base`（唯一约束竞争 → 400，非 500）
- DB 直查每轮仅落 1 行

### 7. base 删除变量零残留 — PASS（当前代码）
- 当前进程 API DELETE base → 200（deleted=true）；DB `nc_base_variables JOIN nc_bases_v2 WHERE deleted=true AND title LIKE 'f05r2b%'` → 删除后 0 残留（主 base 12 行变量随删除全清，两轮取证一致）
- fix 位置确认：`packages/nocodb/src/models/Base.ts` `Base.softDelete`（401 行起）内 453 行 `await BaseVariable.deleteByBaseId(...)`——软删路径（controller DELETE → bases.service.baseSoftDelete → Base.softDelete）真实调用
- 注记（数据残留，非当前代码 error）：fix 编译进 dev 进程**之前**删除的 base 有 2 行历史孤儿（D_KEY1/D_KEY2，其一为 secret 密文）——fix 不回溯存量孤儿；本路已手清。另观察到其他会审路的旧删 base 亦有同类残留行（SECRET_KEY/API_ENDPOINT 等），同因（旧进程期删除），未代清

### 8. 缓存 — PASS
- PATCH `{"value":"after"}` 后立即单条 GET → value='after'（无旧值回读）
- DELETE 后 GET → 404 `Variable not found`

## 观测项（非 error）
- **进程生命周期异常观测**：R2 fix 编译前的旧 server 进程（pid 41096）中，SECRET_A 单条 GET 曾连续返回 `value:""`；server 重启（新编译）后同一 DB 行 3 连 GET 均为 `plain-A-value`，且本地用进程 env key 解 DB 密文得正确明文（密文本身无误）。旧进程已消亡，根因不可确证（疑 rspack hot-restart 中间态/新旧编译混合），当前进程不可复现 → 不判 error，留观测；建议后续轮若复现优先核对 server 进程编译代次

## 环境事件（非 F05 范畴，供编排方知悉）
- 并行会审各路共享 admin 账号 signin 互踩 token_version：任一路 signin 立即废掉他路已签发 JWT（GlobalGuard guest fallback → 403/401）。本路改用专用账号 f05r2b@ce-ee.local（workspace w9qi3ljd creator）规避；账号保留供后续轮复测
- 测试期间 dev server 因他路改码触发多次 rspack 重编译重启（约 5 次进程更替），一度中断测试；以 signin 成功为就绪信号重试后恢复

## 裁决结论

**PASS（无 error）**：8 项全过。两处非 error 注记（type:1/null 回落默认语义；历史孤儿行已手清）与一个不可复现观测项已如实记录。
