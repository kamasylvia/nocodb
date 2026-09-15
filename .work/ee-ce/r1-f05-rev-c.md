# r1-f05-rev-c — 交叉面复审（安全/加密/一致性）

复审人：第 5 路（独立）。范围：F05 Variables 全部 diff + BaseVariable model + 全仓消费面。
隔离声明：未读任何 r*.md 报告；仅读 TASK.md、GOAL-STATE.md(F05 段)、源码、backend.log。

## 结论：issues 列表（3 low，0 error）

### Issue 1 (low)：list 掩码不变量可经 `default_value` 路径绕过

- `packages/nocodb/src/services/base-variables.service.ts:109-114` — `maskSecret` 只清 `value`，未清 `default_value`；service:17-18 注释声明「decrypted value is only served by the single-variable get」，该不变量被破坏。
- 可达链（完整）：
  1. `PATCH /api/v2/meta/bases/:baseId/variables/:variableId` body 带 `default_value` → `service.update` 整体透传 `body` → `BaseVariable.update`；
  2. `packages/nocodb/src/models/BaseVariable.ts:250-259` — `extractProps` 白名单含 `default_value`，secret 行写库前加密（:286-295）；
  3. list 读回：`BaseVariable.ts:78-90` `prepareForRead` 对 secret 行解密 `default_value`（:85-88）；
  4. `maskSecret` 只处理 `value` → 响应携带**解密后的 `default_value`**。
- 影响：creator+（与 GET 单条同受众，无跨权限提升）→ low；但 list 响应从此携带 secret 材料，违反掩码契约。
- 建议：`maskSecret` 同时清 `default_value`（一行修复）；或 `BaseVariable.update` extractProps 去掉 `default_value`（meta 字段本不该经 REST PATCH 改）。

### Issue 2 (low)：服务端 ACL 未注册 baseVariable*，前后端权限地图漂移

- `packages/nocodb/src/utils/acl.ts` — `permissionScopes.base` 数组与 `permissionDescriptions` 均无 `baseVariableList/Create/Update/Delete`（全文件 grep 0 命中）；对比同类新 op `extensionList` 双处注册（acl.ts:261、:503）。
- 功能面无洞：creator/owner 为 exclude 模式（acl.ts:631-643，未列即放行）→ creator+ only 成立；editor(:525)/viewer/commenter 为 include 模式，未列即拒；guest 空 include 拒。与 GOAL-STATE F05 记录声明一致，非本次新设计缺陷。
- 实际后果：① 权限拒绝报错降级为 `perform the action "baseVariableList"` 通用文案（generateReadablePermissionErr fallback）；② 前端 `packages/nc-gui/lib/acl.ts:137-140` 显式注册而服务端隐式放行，双源易漂移。
- 建议（backlog 级）：服务端 `permissionScopes.base` 补 4 个 op + description。

### Issue 3 (low)：UI 文案「encrypted at rest」在 key 未配置部署中失实

- `packages/nc-gui/lang/en.json` 新键 `baseVariablesSubtitle: "…Secret values are encrypted at rest."`（zh-Hans 同步）。
- 实测 dev 环境 **NC_CONNECTION_ENCRYPT_KEY 未配置**：运行中后端进程（PID 31016，backend.log 对应实例）`ps eww` 环境计数 = 0；仓内无含该键的 `.env`；`dev-backend.sh` 不含该键。→ `getCredentialEncryptSecret()` 返回 undefined → `BaseVariable.ts:47-51` `encryptValue` 直通明文落库（cache 同步明文）。
- 风险等级判定：CE 继承行为（`utils/encryptDecrypt.ts` `encryptPropIfRequired` 对连接 config 同款直通，:24-27），**非 F05 回归**。dev 库明文 = 中低（dev DB 本就存明文连接凭证）；生产未配 key 则 secret 变量明文 at rest，与连接凭证同风险面。advisory/backlog，非阻塞。
- 建议：文案条件化（key 未配置时不声称加密）或至少不动（上游同款问题，记 backlog）；另可参考 `helpers/initDataSourceEncryption.ts:10-14` 对缺 key 的显式告警，variables 无对应告警。

## 加密强度评估（任务要求，不改码）

- `CryptoJS.AES.encrypt(text, passphrase)`（BaseVariable.ts:50）= OpenSSL EVP_BytesToKey 派生：MD5、**单轮迭代**、随机 8 字节盐 → AES-256-CBC，无认证标签（malleable，完整性无保障）；`decryptValue` catch-all 返回原文（:56-60）规避了 padding-oracle 报错侧信道，但无篡改检测。
- 建议（backlog）：迁移 `node:crypto` AES-256-GCM + PBKDF2/scrypt 高迭代派生。注意与 CE 全仓加密机制（连接凭证同款 CryptoJS 派生）保持一致优先——单点升级会造成加解密双轨，宜整体迁移，F05 不单动。

## PASS 项（核验证据）

- **内部 batch 不暴露未掩码读**：`nocodb-sdk/src/lib/internalBatch.ts:88` `baseVariableList` 仅为前端批并提示（文件自述 "the backend doesn't enforce this list"）；服务端 internalApiModules 无该 op 注册（全仓 grep：仅 controller @Acl 两处），`Api.ts` 无 baseVariable 方法 → 无调用方可经 SDK/batch 触达；强发未知 sub-op 走 internal.controller 模块表查不到即失败。REST list 唯一出口=新 controller（掩码）。
- **BaseVariable.list 消费者全查（含 sandbox/继承）**：仅 3 处——service list（掩码）、service `validateUniqueKey`（服务端内部比较）、`listAsMap` → `utils/webhook-invoker.ts:378`（服务端 webhook 模板解析，变量功能的设计用途，非 REST 暴露）。无 sandbox/inheritance 消费者（grep 0）；`meta.service.ts:189` `bv` 为 ID 前缀表，非导出路径。
- **权限判定（任务 3 结论）**：GET 单条 `@Acl('baseVariableList')` 受众 = base-scope creator+；解密值可读者与配置管理者（creator）重合，符合 EE「creator 管配置」语义，**非越权面**。观察项（不判违反）：API token（creator 等价）可读 secret，未设 `blockApiTokenAccess`，与 base 配置类 API 上游惯例一致。
- **一致性**：`// [CE-EE]` 标记覆盖全部 8 个代码改动文件（2 新文件 + 6 修改；lang i18n 键不适用标记约定）；`Api.ts` 未动（git status 无 sdk 改动）；`isEeUI` 未翻转（diff 0 命中，仅 `blockBaseVariables` → false）；`.work` 不入库（git status 无）；改动清单（8 M + 2 ??）与 GOAL-STATE F05 实现记录逐项一致。
- **编译/日志**：`npx tsc --noEmit` 实跑 exit 0、0 error；backend.log（:12221-12230）v1+v2 × GET/POST/PATCH/DELETE 共 10 条 variables 路由全部映射成功，`Nest application successfully started`，日志尾部无 variable 相关 error。
