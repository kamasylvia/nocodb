# r3-f05-int-b — F05 Variables 集成测试·对抗面(独立第 2 路, 第 3 轮)

环境: dev server 127.0.0.1:8080 复用(未重启未杀); DB 直查 nocodb-dev(pg8000, Infisical KDL DB_*, host qnap.elf-balance.ts.net, 未触生产库); 账号 f05r3b@ce-ee.local(新注册)/f01e2e@ce-ee.local(owner); 资源前缀 f05r3b_, 两测试 base 已删, 变量零残留。

## 裁决: 1 error

## issues

1. `packages/nocodb/src/services/base-variables.service.ts:45` — **create 路径非法 type 返回 500, 应 400**(任务3"非法输入矩阵 type 全项 400"违反)。根因: `const type = validateVariableType(body.type)` 裸调用未包 `safeValidate`(同函数 L46-47 的 value/key 均已包), `BaseVariableValidationError` 逸出被全局兜底为 500。证据(nocodb-dev 实测, 5/5 复现): POST `/api/v2/meta/bases/:id/variables` body `{"key":"F05R3B_TX","value":"v","type":"hacker"|"123"|"true"|["secret"]|{"t":"secret"}}` → HTTP 500, body `{"msg":"Something didn't work as expected...","innerError":{"msg":"Variable type must be one of: text, secret","stack":"Error: ... at validateVariableType (src/helpers/baseVariableValidators.ts:46:11) at BaseVariablesService.create ..."}}`。PATCH 同输入已正确 400(`{"msg":"Variable type must be one of: text, secret"}`, 本轮实测), 仅 create 漏包, 修复建议: `const type = this.safeValidate(() => validateVariableType(body.type));`

## 逐项结论(证据均为 nocodb-dev 实测)

1. **缓存双重解密回归守卫(R2 核心修复): PASS**
   - secret 创建 → 单条 GET 连读 5 次恒 `s3cr3t-v1`(全 200); list/GET 交替 ×3: list 该行无 `value` 字段(掩码), GET 恒 `s3cr3t-v1`; PATCH value=`s3cr3t-v2` → GET 连读 3 次恒 `s3cr3t-v2`, DB 密文以 dev key 解密=`s3cr3t-v2`。DB 全程 `U2FsdGVk%` 密文形态。
2. **加密状态机四步(F05R3B_SM): PASS**(DB 密文形态 + API 读值 + list 掩码三面核对)
   - A 建	text `sm-plain-A`: DB 明文=值本身; API=; list 显示明文(text 不掩码) ✓
   - B PATCH type=secret(值不动): DB 变 `U2FsdGVk%` 密文且解密=`sm-plain-A`; API=`sm-plain-A`; list 掩码 ✓
   - C PATCH value=`sm-plain-B`: DB 新密文(≠旧密文), 解密=`sm-plain-B`; API=`sm-plain-B`; list 掩码 ✓
   - D PATCH type=text: DB 明文=`sm-plain-B`; API=; list 显示 ✓
   - 密文解密验证: node crypto-js + NC_CONNECTION_ENCRYPT_KEY(dev key)逐步 round-trip。
3. **非法输入矩阵: FAIL**(见 issues#1; 其余全 PASS)
   - key: lowercase/空/缺失/数字开头/连字符/超 255 → 6/6 400, 消息正确(UPPER_SNAKE_CASE / required / 255 limit) ✓
   - value: int/object/array/bool → 4/4 400 "Variable value must be a string" ✓
   - type: bogus/int/bool/array/object → 5/5 **500**(error); type:null → 200 默认 text(validator 设计 null=未提供, 与 PATCH 语义一致, 注记非 error) ✓除 500 外
   - PATCH 侧: type bogus/value int/value object/改 key/空 body → 5/5 400 ✓; 矩阵后存量行值无污染(DB 核对)。
4. **PATCH 语义(R2 修复回归): PASS**
   - `{"value":null}` → 200, GET value=""(清空) ✓; 仅 `{"description":"only-desc"}` → 200, value 不动("") ✓; 置 `real-val` 后再 desc-only patch → 200 且 value 仍 `real-val`(API+DB 双核对) ✓; secret 行 desc-only → 200 且 value 仍 `s3cr3t-v2` ✓(L107-110 ensureEncryptionAvailable 不误伤 desc-only)。
5. **删 base 零残留: PASS**
   - 两测试 base(paw1ys7yytbde2r/pev7saoqxnurfky, 删前分别 5/4 行变量)DELETE 后 `nc_base_variables` 直查 = 0 行 ✓。注记: `nc_base_users_v2` 保留 owner 行且 base.deleted=true — 软删保留成员属 CE 核心语义, 非 F05 范围, 不计 error。
6. **权限矩阵: PASS**
   - 无 token: GET variables(v1/v2 路由) → 401 ✓
   - 无角色(f05r3b=org-level-viewer, 非 base 成员): list/create/get → 3×403 "Forbidden - Unauthorized access" ✓
   - editor(DB 降权实测): `nc_base_users_v2` 插 roles='editor' 行后, B list → 403、create → 403, 消息含 `with the roles: Editor.`(角色确已解析为 editor, 非无角色误判) ✓; 删行后回 403 无角色态 ✓。读码印证: acl.ts EDITOR 为 include 型且不含 baseVariable*(L531 起), CREATOR/OWNER 为 exclude 型未排除 → creator+ only 生效。
7. **并发同 key: PASS**
   - 5 并行 POST 同 key codes = `200,400,400,400,400`(1 成 4×400, unique violation 落 400 非倒是 500), DB 该 key 恰 1 行 ✓
8. **UI 契约抽查: PASS**
   - GET 单条响应含 `id/key/value/description/type`(text 与 secret 均核), secret 的 value 为解密明文供编辑预填; 与 `packages/nc-gui/components/dashboard/settings/base/Variables/index.vue:56-67` openEditModal 直接展开 `res.data` 预填的用法吻合 ✓

## 脚本伪影声明(非产品问题)
- 首轮 results.txt 中 list 类 FAIL 系测试脚本按 `{"list":[...]}` 解析, 实际响应为裸数组, 已修正重跑(R1/R2 全 PASS); T7 grep 计数受 cat 无换行合并影响, codes 原串已留证。
- 测试期间 dev server 出现一次外部重启(rspack watch, 非本路操作), 已等恢复后继续; token_version 外部轮换致 A 账号 token 偶发失效, 脚本内自动重签缓解。
