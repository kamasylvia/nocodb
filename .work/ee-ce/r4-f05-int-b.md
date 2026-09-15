# r4-f05-int-b — F05 Variables 第 4 轮收敛确认（集成测试-对抗面, 第 2 路）

**PASS**

0 issues。

## 验收明细（7 项全 PASS，附证据）

### 1. R3 修复回归：create type 非法 → 400 非 500 — PASS
create type=`"bogus"`/`123`/`true`/`["array"]`/`{}` 各发一次：
- 全部 HTTP 400，body `{"msg":"Variable type must be one of: text, secret"}`，0 个 500。
- PATCH 同型非法 type 亦 400（见矩阵）。

### 2. 缓存守卫 — PASS
- secret GET×5：codes=[200×5]，values 恒 `cache-secret-v1`（无双解密变空/变乱码）。
- list/GET 交替×3：GET 恒明文 `cache-secret-v1`，list 行 value 恒 None（掩码），seq=[('cache-secret-v1',None)×3]。
- PATCH 后 GET×3：values 恒 `cache-secret-v2`；list 仍掩码。
- DB 对照：cache 命中下 API 返回明文、DB 仍密文 `U2FsdGVkX19J...`（缓存存原始密文，读取路径解密副本，不污染缓存）。

### 3. 加密状态机四步 DB+API+掩码三面核 — PASS
（uv pg8000 查 `qnap.elf-balance.ts.net:5432/nocodb-dev`.`nc_base_variables`，逐步快照；未触碰 nocodb 生产库）
| 步 | 操作 | DB 面 | API get 面 | list 掩码面 |
|---|---|---|---|---|
| 1 | create PLAIN `plain-alpha` | value=`plain-alpha`（明文, type=text） | `plain-alpha` | 明文 |
| 2 | PATCH type→secret | value=`U2FsdGVkX19b7MJJ...`（密文, type=secret） | `plain-alpha`（解密回原值） | None |
| 3 | PATCH value=`secret-beta-2` | 新密文 `U2FsdGVkX1/hLvkj...`（≠步2密文） | `secret-beta-2` | None |
| 4 | PATCH type→text | value=`secret-beta-2`（明文, type=text） | `secret-beta-2` | 明文 |

密文均为 CryptoJS AES `U2FsdGVk` 前缀（NC_CONNECTION_ENCRYPT_KEY 已由 dev-backend.sh 注入），步2/步3 翻转重加密、步4 解密落明文，三面一致。

### 4. 非法输入矩阵全 400 — PASS
- key 6 项：null/缺失/空串 → `Variable key is required`；小写 `abc`、带连字符 `MY-VAR` → `must be UPPER_SNAKE_CASE`；256 字符 → `exceeds 255 characters limit`。全 400。
- value 4 项：`123`/`true`/`{}`/`[]` → `Variable value must be a string`。全 400。
- type 5 项：`"bogus"`/`123`/`true`/`[]`/`{}` → `must be one of: text, secret`。全 400。
- PATCH 5 项：改 key → `cannot be changed. Delete and recreate`；type 非法/value 非串/description 非串 → 对应 400；空 body → `Nothing to update`。全 400，且 5 连拒后行数据原样（key/value/description 未动）。

### 5. PATCH 语义 — PASS
- `{"value":null}` → 200，get.value=`''`（清值）。
- desc-only（`{"description":"desc-only"}`）→ 200，value 保持不动。
- secret 行 desc-only → 200 不误拒（value `sv1` 保留、desc 更新）；secret 行 value-only PATCH 同样 200（`sv2`），encryption 守卫不误伤。

### 6. 删 base 零残留 + 并发同 key — PASS
- 删 base（含 2 text + 1 secret 变量）→ API list 404 `Base not found`；DB `nc_base_variables` 该 base_id 0 行；两个已删 res base 与主 base 三处 DB 终验全 0 行。
- 并发同 key create（5 线程）×3 轮：每轮 codes 恒 `[200,400,400,400,400]`（1 成 4×400，DB unique constraint 兜底生效，无 500）。

### 7. 权限 — PASS
- 无 token → 401 `ERR_AUTHENTICATION_REQUIRED`。
- 无角色（signup 后未 invite）→ list/create 403 `Forbidden - Unauthorized access`。
- editor 降权 → list/create/patch/delete 全 403，消息明确：`permission to perform the action "baseVariableList" with the roles: Editor`（ACL creator+ 收口正确）。

## 环境备注（非产品问题，不计违反）
- dev server 冷启动 ~4 分钟，rspack autoRestart 窗口内脚本遇 Connection refused/401（token_version 随共享账号重签轮换）；改用专用账号 f05r4b（invite 为 base creator）后稳定，未重启未杀 server。
- 测试脚本自身两处缺陷（list 裸数组解析、res base 未授权 token）已修正重跑，均非产品缺陷。
- 缺 `NC_CONNECTION_ENCRYPT_KEY` 时 secret 禁写守卫（400）无法在本 server 实测（dev key 恒注入），属代码复审面。

## 资源清理
f05r4b_advbase（主 base）、f05r4b_resbase×2 全部删除；DB 变量表 0 残留。测试脚本与原始输出存 `.work/ee-ce/f05r4b_run1.py` / `f05r4b_t3db.py` / `f05r4b_run2.py` 及 `*_out.json`。
