# r1 F05 Variables 集成测试 — 第 2 路（集成测试-对抗面）

环境:dev server 127.0.0.1:8080(NC_DB=nocodb-dev,进程实测无 NC_CONNECTION_ENCRYPT_KEY);测试 base pihdmjv69zx7yki(已删);DB 直查走 pg8000 → qnap.elf-balance.ts.net/nocodb-dev(未触碰 nocodb 生产库)。资源前缀 f05r1b_,测毕 API+DB 双清(row count=0)。

## 验收项

### 1. secret 加密落库 — FAIL

- 实测:POST type=secret value=`f05r1b_plaintext_A` → 200;pg8000 直查 `nc_base_variables`:`type=secret, vlen=18, head='f05r1b_plaintext_A', cryptojs=False` — **DB 明文,非密文**。
- 根因(dev server 进程 env 实测,`ps eww`):无 `NC_CONNECTION_ENCRYPT_KEY`。`src/models/BaseVariable.ts:47-51` `encryptValue` 在 `!secret` 时原样返回明文,静默降级无任何警告。
- issues 列表:
  - `packages/nocodb/src/models/BaseVariable.ts:48-50`:NC_CONNECTION_ENCRYPT_KEY 未配置时 secret 值静默明文落库,无日志/警告;生产环境漏配该 env 时秘密零加密且不可察觉。建议:启动时或 encryptValue 首次降级时打 warning,或配置缺失直接拒绝 secret 写入。
  - 部署面:当前 dev 实例未设 NC_CONNECTION_ENCRYPT_KEY,导致 T1 语义(密文落库)在本环境不成立。

### 2. type 切换加密状态机 — PASS

- S0 text 单读:`value='f05r1b_valueA'`,list 有值。
- PATCH type=secret → 单读 A 明文(`value='f05r1b_valueA'`),list 掩码(`list_value=None`)。
- PATCH value=B(secret)→ 单读 `value='f05r1b_valueB'`,list 掩码 None。
- PATCH type=text → 单读 B 明文,list 有值。
- DB 断言(切换中点密文):受 T1 根因牵连,本环境 DB 全程明文,该子断言无法达成(同 T1 issue,API 状态机本身全对)。

### 3. 64KB 边界 — PASS

- create 65535 → 200,回读 len=65535。
- create 65536 → 200,回读 len=65536。
- create 65537 → 400 `{"msg":"Variable value exceeds 64KB limit"}`。
- PATCH 既有变量至 65537 → 400 同消息。阈值精确(>65536 拒)。

### 4. 非法 payload — issues 列表

- 空 body `{}` PATCH → 200 无变化(合理 no-op)。
- key 含空格 / 中文 / 数字开头 → 400 `Variable key must be UPPER_SNAKE_CASE`(PASS)。
- value 数字 12345 → 200,归一 string `"12345"`(合理)。
- value 对象 `{"a":1}` → 200,JSON.stringify 落库(合理)。
- issues 列表:
  - `packages/nocodb/src/controllers/base-variables.controller.ts:57` + `src/services/base-variables.service.ts:39,44` + `src/models/BaseVariable.ts`:type 无枚举校验。create `type:"weird"` → 200,DB 落库 `type='weird'`;PATCH 同样 200 落库。脏 type 使 list 掩码/isSecret 分支全部按非 secret 处理。建议:create/PATCH 校验 type ∈ {text,secret},否则 400。
  - `packages/nocodb/src/services/base-variables.service.ts:75` + `src/models/BaseVariable.ts:215,261`:64KB 检查依赖 `value.length`,非 string(对象/数组)`.length` 为 undefined → 绕过限制。实测 value 为嵌套对象(内含 70000 字符)→ 200,DB 落库 70008 字符。建议:先做 typeof value === 'string' 校验,非 string 拒 400。
  - key 300 字符 → HTTP 400 但错误体为 `ERR_DATABASE_OP_FAILED / code 22001`(DB 层 key 列 255 上限报错),KEY_REGEX 未限长,应用层缺长度校验,错误语义误导。建议:KEY_REGEX 或 service 校验 key ≤ 255 返 400 友好消息。

### 5. 不存在 / 跨 base id — PASS

- 随机 id `aaaaaaaaaaaaaaaaaaaa`:GET 404 / PATCH 404 / DELETE 404(`{"msg":"Variable not found"}`)。
- 跨 base(本 base 变量 id + Getting Started base 路径):GET/PATCH/DELETE 全 404。

### 6. 大小写 key 变体 — PASS

- `api_endpoint`、`Api_Endpoint` → 400(KEY_REGEX `/^[A-Z][A-Z0-9_]*$/` 强制全大写,大小写变体不可能入库,不存在等价 key 歧义)。`src/models/BaseVariable.ts:18`。
- 精确重名 `API_ENDPOINT` → 400 `already exists in this base`。
- 判定:设计合理 — key 空间规范化为单一大小写形态,冲突面收敛。

### 7. 并发创建同 key ×5 — PASS(带瑕疵)

- 实测:恰 1 成功(req3,value=r3),4 个 HTTP 400,DB unique `nc_base_variables_ws_base_key_unique` 兜底生效。
- issues 列表:
  - `src/services/base-variables.service.ts`(validateUniqueKey 竞态路径兜底):并发失败方返回 `ERR_DATABASE_OP_FAILED` 且消息误导("fk_workspace_id field unique constraint violation",实为 (fk_workspace_id,base_id,key) 复合唯一约束),非业务化 400 语义。建议:捕获 unique violation 转 `Variable key already exists`。功能正确性已达标(恰 1 成功),仅错误呈现问题。

### 8. 缓存一致性 — PASS

- PATCH value 后立即单条 GET:`value='f05r1b_updated_x9'`(新值即时可见)。
- DELETE → 200 true;GET → 404;list 中无该 key 残留。

## 额外发现(base 删除级联)

- issues 列表:
  - base 删除流程未清理变量:DELETE base 200 后,`nc_base_variables` 残留该 base 全部 9 行(孤儿行含 secret 明文),仅靠手工 SQL 清除。`src/models/BaseVariable.ts:338` `deleteByBaseId` 存在但 base 删除链路未调用。建议:base delete hook/流程接入 BaseVariable.deleteByBaseId。

## 裁决

- PASS:T2(API 状态机)/T3/T5/T6/T8;T7 功能达标。
- FAIL:T1(secret 加密落库 — 本环境明文,根因 env 缺失 + 代码静默降级)。
- Issue 计 5 条:加密静默降级、type 无枚举校验、对象 value 绕过 64KB、key 超长 DB 报错、base 删除不清理变量行;另有并发竞态错误消息误导(不改变功能判定)。
