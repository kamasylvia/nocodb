# r2-f05-int-a — F05 Variables 第 2 轮 集成测试(第 1 路:正向+边界)

实测环境:dev server http://127.0.0.1:8080(nocodb-dev),管理员 f01e2e@ce-ee.local,资源前缀 f05r2a_,base1=pazim6iza4y6ia7、base2=psjxzvt4snovyel(测毕已删 + 孤儿 schema 已 DROP + 变量行已清,DB 复核 remaining=0)。

## issues

### ISSUE-1(int-a):secret 变量值一经读取即返回空串(数据读回丢失)
- 文件:`packages/nocodb/src/models/BaseVariable.ts` : `public static async get`(cache-miss 分支)与 `list`(同一模式)
- 现象(全实测):
  - POST 创建 secret `F05R2A_SECRET_FULL`(value="supersecret123")→ create 响应回显明文 `supersecret123`(HTTP 200)
  - 随后 GET 单条 `/api/v2/meta/bases/{baseId}/variables/{id}` → HTTP 200 但 `"value":""`(期望 `supersecret123`);3 个 secret 样本(FULL/EMPTYVAL/NODEF)中 2 个非空值全部读成 `""`
  - list 同样:`"value":""`
  - DB 直查(nocodb-dev `nc_base_variables`,pg8000):两行 value 为密文 `U2FsdGVkX1/...`(44 字节)——加密 at-rest 正常,数据没丢,是**读取路径坏**
- 根因:`BaseVariable.get` cache-miss 分支中 `NocoCache.set(context, key, data)` **未 await**,且下一行 `prepareForRead(data)` 对**同一对象引用就地突变**(data.value 明文化)。set 内部先 `await getRaw(key)` 让出事件循环,序列化(`JSON.stringify`)发生突变之后 → **cache 里存的是明文**。下次 GET 命中 cache(明文)→ `prepareForRead` 再次解密 → `CryptoJS.AES.decrypt(明文).toString(Utf8)` 不抛错、静默返回 `""`。list 路径同理(mget parse 后的就地突变对象虽不入 cache,但 cache 早已被 get 写脏)。
- 佐证:经 PATCH type 双向切换产生的 secret(text→secret,走 `NocoCache.update` 存密文)GET 解密正常(`val3` 正确往返)——只有 insert 时经 get 写入的 cache 是脏的
- 影响:任何 secret 变量创建后,值在 cache TTL 内永远读不回(单条+列表),webhook `listAsMap` 等消费方拿到空串
- 建议:`await NocoCache.set(...)` 并让 `prepareForRead` 返回浅拷贝(或 set 先深拷贝快照),二选一即可;`list` 的 cache set 与 prepareForRead 同样处理
- 注:该缺陷在 CE 原生 model,F05 service 首次把它暴露到 meta API;掩码逻辑本身(列表 value→""、default_value 键消失)与 R1 修复点无冲突,但列表里 `""` 实为双重解密产物而非掩码效果

### ISSUE-2(int-a):删 base 后 DB 残留孤儿变量行(R1 修复挂错删除链)
- 文件:`packages/nocodb/src/models/Base.ts` : `static async delete` 中新增的 `BaseVariable.deleteByBaseId`(diff 段);对照 `static async softDelete`
- 现象(全实测):
  - DELETE `/api/v2/meta/bases/{baseId}` 对 base1/base2 均 200
  - DB 直查:`nc_base_variables` 残留 **9 行**(含 2 条加密 secret);`nc_bases_v2.deleted=true`(软删);`information_schema.schemata` 残留 2 个同名 schema
  - 全库佐证:36 个软删 base 中抽查 8 个,除 1 个外全部残留变量行(f05_e2e/f05dbg/r2c_sec 等历史现场同样中招)
- 根因:DELETE base API 走 `BasesService.baseSoftDelete` → `Base.softDelete`(只 bulkDelete CustomUrl/MCPToken/FileReference + 标记 deleted,**无变量清理**);F05 R1 修复加在 `Base.delete`(硬删链),而全代码库 **无任何 `Base.delete(` 调用者**(grep 证实)→ 修复永不执行
- 建议:把 `BaseVariable.deleteByBaseId` 移到/同加到 `Base.softDelete`(与同函数内 CustomUrl/MCPToken/FileReference 的 bulkDelete 惯例对齐);若 EE 有 purge 流程再评估硬删侧保留
- 注:CE 原生对软删 base 本就保留行(CustomUrl 例外地做了清理),但本任务验收标准是「删 base 后 DB 无孤儿变量行」,且 secret 密文(可解密)残留属安全面,F05 承诺的「base 删除清理」实际未生效

## PASS 项(证据摘要)

- T1 text CRUD + order 自增:**PASS** — 3 连建 order=1/2/3,list 按 order 升序;PATCH value+description 200;DELETE 200;删后新建 order=4(不重用)
- T2 分项:type 双向切换 **PASS**(text→secret→text,value `val3` 三态往返正确);列表掩码机制(default_value 键消失、text 不受影响)**PASS**;但单条解密 **FAIL**(见 ISSUE-1),整项判 FAIL
- T3 key 校验:**PASS** — `lower_case`/`WITH-DASH`/`1START` → 400 UPPER_SNAKE_CASE;重名 → 400 already exists;255 字符 → 200,256 字符 → 400
- T4 type 白名单:**PASS** — `"weird"`/`"Secret"`/`"TEXT"`/`"Text"` POST 与 PATCH 路径全 400(`Variable type must be one of: text, secret`)
- T5 key 不可改:**PASS** — PATCH 改 key → 400 `Variable key cannot be changed`;PATCH key=原值 → 200(不误伤)
- T6 value 类型:**PASS** — object/number/array 经 POST 与 PATCH 全 400 `Variable value must be a string`
- T7 404/跨 base 隔离:**PASS** — 删/查不存在 id → 404;跨 base(base2 URL + base1 variableId)get/delete/patch 全 404;同 key 跨 base 可建(200,唯一性按 base 隔离)
- T9 并发同 key:**PASS** — 10 并发 POST `F05R2A_RACE`:恰 1×200 + 9×400,错误消息统一 `already exists in this base`(预检+DB unique 兜底均未漏)
