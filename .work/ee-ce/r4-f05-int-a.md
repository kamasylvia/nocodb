# r4-f05-int-a.md — F05 Variables 第 4 轮收敛确认 · 第 1 路(集成测试-正向+边界)

日期:2026-09-12。环境:dev server http://127.0.0.1:8080(未重启未杀),DB nocodb-dev(qnap.elf-balance.ts.net:5432,pg8000 直查确认 `current_database()=nocodb-dev`)。
账号:f01e2e@ce-ee.local(owner,建 base + 权限操作);f05r4a@ce-ee.local(本轮注册,先 viewer 后经 base users API 降权/升权实测)。资源前缀 f05r4a_,测完全删。

## 裁决:PASS

57 项断言全 PASS,0 error。R3 修复(safeValidate 包 create 路径 type 校验)回归确认有效。

## 证据

### T1 R3 修复回归(7/7 PASS)
POST /api/v2/meta/bases/{baseId}/variables:
- `type:"bogus"` → 400 `{"msg":"Variable type must be one of: text, secret"}`(非 500)
- `type:123` → 400 同消息
- `type:true` → 400 同消息
- `type:{"a":1}` → 400 同消息
- `type:"text"` value:"v1" → 200
- `type:"secret"` value:"sv1" → 200
- `type:null` → 200 落 text(service fallback `type || TEXT`),响应 type=text

### T2 正向全链路(10/10 PASS)
- text CRUD:创建/GET 明文/PATCH value+description(v2/upd)全 200。
- order:list 返回 `[1,2,3,4,5]` 严格递增(按创建顺序分配,metaGetNextOrder)。
- secret GET×3 恒定 = `sv1`(缓存命中 + DB 回源两路均解密一致;BaseVariable.ts R2 修复——cache 存密文、prepareForRead 解密副本——行为正确)。
- list 双掩码:secret 行 JSON 无 `value`/`default_value` 字段(maskSecretVariable);同行 text 变量 list 中 value 仍明文可见(v2)。
- type 双向切换:text(v2)→secret → GET 仍 `v2`;secret→text → GET 仍 `v2`(model update 的 typeFlipped 重加密/解密路径正确)。

### T3 校验矩阵 / 不可变 / 404 / 隔离(33/33 PASS)
- key:create 小写/空/缺失/123/连字符/数字开头/带空格/256 字符 → 全 400;255 字符合法 → 200(`[A-Z][A-Z0-9_]*$` + 255 上限)。
- value:create 对象/数组/数字/bool → 400「must be a string」;65537 → 400;65536 边界 → 200。
- PATCH 路径:type=123 → 400;value=obj → 400;description=obj → 400;空 body → 400「Nothing to update」。
- key 不可改:PATCH `{"key":"F05R4A_NEWKEY"}` → 400「Variable key cannot be changed. Delete and recreate」;PATCH 同 key + description → 200。
- 删除:DELETE → 200;随后 GET/PATCH/DELETE 该 id → 全 404「Variable not found」;bogus id → 404。
- 重复 key:同 base 二次 POST 同 key → 400「already exists in this base」。
- 跨 base 隔离:base A 的变量经 base B 路径 GET/PATCH/DELETE → 全 404;base B list 0 条 base A 行;不同 base 同 key 可各建(200)。
- 加密落库旁证:secret 创建响应 value="sv1" 而持久层密文(模型 encryptValue),GET×3 恒定 + list 掩码证明加解密链路一致。

### T4 并发同 key(PASS)
5 个并行 POST 同 key `F05R4A_RACE`(pre-check count=0):codes = 1×200 + 4×400;终态 API list 该 key 行数 = 1(isUniqueViolation → 400 回退路径生效,未漏 500)。

### T5 删 base 零残留(PASS)
DELETE 两 base → 200;其 variables API → 404。pg8000 直查 nocodb-dev:
- `nc_base_variables WHERE base_id IN (两base)` = **0 行**;`key LIKE 'F05R4A%'`(含小写)全库 = 0 孤儿。
- `nc_bases_v2` 两行 deleted=true(系统标准 soft-delete,非变量残留)。
- pg schema:两 base 各留 1 个**空** schema(0 表)。判定:非 F05 引入——全库近 25 个 base 中 24 个已删、22 个同样残留 schema,属上游 base 删除既有全局行为;F05 变量数据本身零残留。两个空壳 schema 已按清理义务 DROP(先断言 0 表),复核 remaining=0。

### T6 权限(PASS,实测)
- base **editor**(经 POST/PATCH /meta/bases/{id}/users 真实 API 设置角色):variables list/create/update/delete → **全 403**,错误消息带权限名与角色(`baseVariableCreate ... roles: Editor` 等 4 条)。
- base **creator**(API 改角色):list 200 / create 200 —— 与 acl.ts 中 `[CE-EE] F05: base variables management (creator+ only)` 及 controller 注释声明一致。
- org viewer(未加入 base):create/list → 403。owner:全 200。
- 判定依据:acl.ts permissionScopes.base 含 baseVariableList/Create/Update/Delete;include 继承链(VIEWER→COMMENTER→EDITOR)不含 baseVariable*,实测行为与读码一致。

## 观察项(非 error,不计违反)
1. 集成首轮中 1 次 GET base B variables 返回 404(同脚本 49 请求成功、token 有效);精确复现序列 3 轮均 200,单发亦 200,判瞬态(疑 dev server 抖动),非产品缺陷。
2. NocoDB 上游删 base 不 DROP pg schema(22/24 残留,空壳),属 base 生命周期上游行为,F05 范围外;如需整治另立任务。

## 清理确认
两测试 base 已 DELETE(200);变量表 0 残留;自建空 schema 已 DROP;测试账号 f05r4a@ce-ee.local 保留供后续轮复用;f05r4a 在 base A 的成员关系随 base 删除。脚本存 `.work/ee-ce/tmp-r4-f05/`。
