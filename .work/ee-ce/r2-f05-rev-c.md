# r2-f05-rev-c.md — 第 5 路交叉面复审（F05 R2）

复审面：安全终审 + 一致性 + 测试基建 + 文档同步 + 终局清单。DB/API 均为 nocodb-dev 实测（pg8000 直查 nc_base_variables + :8080 API），凭证运行时拉取未落盘。

## PASS 项（核验通过，简列）

1. **list 掩码**：secret 行 value/default_value 均剥离（API 实测 `.value:""`，读码 service.maskSecret 双字段同剥）；text 行明文保留，符合设计。
2. **DB 密文**：secret 行落库值为 `U2FsdGVkX1/...`（CryptoJS AES），非明文（pg8000 实测）；text 行明文为设计内。
3. **单条 get 解密 + creator-only**：ACL 服务端 creator 为 exclude 模型放行、editor/viewer/commenter include 无 baseVariable* → 无角色用户对 list/create/get 实测 3 端点全 403；前端 lib/acl.ts 仅 CREATOR include 4 op。
4. **NC_CONNECTION_ENCRYPT_KEY 不入库**：`git ls-files | xargs grep "dev-only-ce-ee-encrypt-key"` 0 命中；变量名命中文件均为上游原生引用（charts/nc-secret-mgr/encryptDecrypt.ts 等）；dev-backend.sh 被 `.gitignore:139` 覆盖（`git check-ignore -v` 实证）。dev server 进程 env 实证带 key（ps eww）。
5. **Api.ts / isEeUI 未动**：git status 无 `packages/nocodb-sdk/src/lib/api.ts`、`packages/nc-gui/utils/ncUtils.ts`。
6. **改动清单与 GOAL-STATE F05 记录一致**：2 新（service/controller）+ 10 改（module/Base.ts/acl×2/useEeConfig/View.vue/BaseSettingsMenu/Variables/index.vue/lang×2），无多余文件。
7. **tsc --noEmit 实跑**：exit 0，输出空。
8. **backend.log**：无 F05/base-variables 相关错误、无 500；BaseVariablesController 已注册（RoutesResolver 行）；尾部 401 Token Expired 为并发会审路过期 token 噪音（非 F05）。
9. **f05-e2e.sh 幂等读码**：base 名带 `date +%s` 时间戳、signup→signin fallback、trap cleanup + 正常流末尾清 CREATED_BASE 防 double-delete。
10. 契约核验：noco.module 注册、MetaApiLimiterGuard+GlobalGuard、extract-ids 把 `:baseId` 填入 context.base_id（validateUniqueKey 用 context.base_id 与参数等价）、SDK `BaseVariableValueType{TEXT,SECRET}`、isUniqueViolation 多驱动形态、Modal/message 自动导入（nuxt.config imports）、i18n en/zh 键对称（labels.key/value/type、msg.info/error/success 各组）、`title.baseVariables`/`labels.description` 上游已有。

## Issues

### E1（error，必修）secret 二次读恒返回空串 —— 缓存污染，单条 get 解密承诺失效

- 位置：`packages/nocodb/src/models/BaseVariable.ts:78-90`（prepareForRead）+ `:92-125`（get）+ `:127-164`（list）
- 实测（3 次复现，nocodb-dev）：create secret 响应回显明文（insert 内部首次 get）→ 此后对同一变量的**所有** list/get API 读取 value 均为 `""`；`DELETE /api/v2/meta/cache` 后立即 get → 明文恢复。缓存污染闭环实锤。
- 根因：dev 无 Redis → `RedisMockCacheMgr`（ioredis-mock，对象按引用语义存储）；`prepareForRead` 原地 mutate 缓存中的行对象，密文被覆盖为明文；下次读命中缓存后把明文再走 `decryptValue`，CryptoJS 对错误密文解密不抛异常、`toString(enc.Utf8)` 返回空串。
- 影响：API/服务"单条 get 解密"在二次读场景失效；UI `openEditModal` 的 secret 预填（list 之后必走缓存）拿恒空值——编辑 secret 功能实际不可用。且解密明文长期驻留缓存对象。
- 修法建议：`prepareForRead` 纯函数化（进入时 `data = { ...data }` 再 mutate），一行修复；或 get/list 缓存命中后浅拷贝再解密。
- 归属：model 为 CE 上游代码，但 F05 是首个 API 暴露面，属本功能必修。R1 未发现原因：f05-e2e 步骤 4 "读单条（secret 解密）"实际 get 的是 **text** 变量 VID1，secret 的 get 解密从未被断言。

### E2（error，必修）base 删除孤儿清理未生效 —— R1 修复挂点不可达

- 位置：`packages/nocodb/src/models/Base.ts:693-695`（`BaseVariable.deleteByBaseId` 挂在 `Base.delete` 硬删内）；实际删除路径 `packages/nocodb/src/services/bases.service.ts:218` = **`Base.softDelete`**
- 实测：`DELETE /api/v2/meta/bases/:id` 返 200，pg8000 查证 base `deleted=true`（软删）而 `nc_base_variables` 两行残留（含 secret 密文行）；全仓 `Base.delete(` 调用点为 **0**（除 spec）→ 挂点为死代码路径；无 purge job 走硬删。
- 影响：R1 修复 #2 注释承诺 "deleted bases don't leave orphan rows (including encrypted secrets)" 未兑现；dev 库已积累 ≥6 行历史测试孤儿（f05-e2e 每跑一轮经 cleanup 留 2 行，各会审路数据可证）。
- 修法建议：`deleteByBaseId` 挂 `Base.softDelete`（CE trash 关闭态下软删即用户视角永久删除；若裁决要保留恢复语义则须明确 purge 路径并同步挂点）。
- 附带观察：`deleteByBaseId` 的 `deepDel` key 形态 `${BASE_VARIABLE}:${baseId}:list` 与 `NocoCache.setList` 实际 list key `${BASE_VARIABLE}`（无 baseId 后缀，per-row key 为 `${BASE_VARIABLE}:${id}`）不符——挂对位置后需复验缓存清理实效（当前 key 删不到任何真实键）。

### L1（low）View.vue watch 行缺 [CE-EE] 标记

- `packages/nc-gui/components/project/View.vue:190`：`!blockBaseVariables.value && isUIAllowed('baseVariableList')` 改动行无标记（同文件 tab-pane hunk 处有注释）。违反"所有修改处加标记"约定，补行尾注释即可。

### L2（low）en.json 杂散无关 hunk

- `packages/nc-gui/lang/en.json:4165` 附近：删除 `"skillPolicyFromOrg"` 后的空行，与 F05 无关的 diff 污染，建议还原。

### I1（improvement/流程）F05 无单测

- TASK.md 工作流步骤 2 要求"补/改单测"；F05 改动面无任何 jest/vitest spec。service 校验逻辑（type 白名单 / 64KB / key 长度 / 无 encrypt key guard）均为可单测纯逻辑。

### I2（improvement/文档）AGENTS.md 缺 NC_CONNECTION_ENCRYPT_KEY dev 约定

- GOAL-STATE（F05-R1 #3）有 "dev-backend.sh 注入 dev key"，AGENTS.md §3 开发环境无记录。新会话只按 AGENTS.md 起后端会漏 key：secret 创建被 400（guard 拒）或旧版本静默明文。建议 §3.1 或 §3.2 补一行 dev key 约定。

### I3（improvement/测试）f05-e2e.sh 缺 secret 单条 get 二次读断言

- 补：create secret → get 单条断言 `value == 明文`（当前只断言 text 变量，正是 E1 漏网原因）；E2 修复后可在 e2e 尾部加 DB 侧孤儿零残留检查（可选）。

## 测试残留说明

复审自建的 2 个测试 base 及关联行已清（pg8000 实删 bases/base_users/sources/variables）。dev 库现存 6 行 `R2C_*/API_ENDPOINT/SECRET_KEY` 变量行属各会审路 f05-e2e 历史累积（E2 的活体证据），未动，留修复轮复验。
