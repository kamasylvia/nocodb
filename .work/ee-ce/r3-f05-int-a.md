# r3-f05-int-a — F05 Variables 第 3 轮 集成测试(正向+边界) 第 1 路

账号 f05r3a@ce-ee.local(专用);base1=f05r3a_base1(po547dcz40yyjzq)、base2=f05r3a_base2(pmk30dzztucwl5s)、base3=f05r3a_base3(plw2mn5s5bf3d2l,已删)。
全程 dev server http://127.0.0.1:8080 实测,xc-auth JWT;共 41+4 项断言。

## 结论

issues:

1. `packages/nocodb/src/services/base-variables.service.ts:45` — POST create 时非法 `type`(如 `"bogus"`、`123`)返回 **500**(应为 400)。根因:`const type = validateVariableType(body.type)` 未包 `this.safeValidate(...)`,`BaseVariableValidationError` 裸抛成未处理异常 → 全局 500 通道,`innerError.msg = "Variable type must be one of: text, secret"`。对照:update 路径(`base-variables.service.ts:88-90`)已包 safeValidate,PATCH 非法 type 实测 400 正确。修法:与 update 同款包裹 `const type = this.safeValidate(() => validateVariableType(body.type))`。证据:
   - `POST /api/v2/meta/bases/po547dcz40yyjzq/variables {"key":"F05R3A_BT2","type":"bogus","value":"x"}` → `500`,`innerError.stack` 指向 `baseVariableValidators.ts:46 ← base-variables.service.ts:45`
   - `type:123` → 同 500;`type:null` → 200(回退 text,合理);PATCH `{"type":"bogus"}` → 400 正确。

## 各项实测结果(除上述 1 条 issue 外全 PASS)

- **T1 text CRUD + order** PASS:3 连建 200;无 type 默认 `text`;order=[1,2,3] 严格递增;GET 单条回读正确;PATCH 回读 `va2`;DELETE 200 后 GET 404。
- **T2 secret 全链路** PASS:
  - 建 secret 200 → 单条 GET 连续 3 次 value 恒等于明文 `f05r3a-s3cret-XYZ`(R2 缓存双重解密回归守卫通过:缓存存密文+读时拷贝解密);
  - list 掩码:secret 行 key 集 = `base_id,created_at,description,fk_workspace_id,id,inheritance,is_inherited,is_overridden,key,order,type,updated_at`,`value`/`default_value` 均不出现;text 行 value 正常返回;
  - type 双向切换:text→secret(x3 读恒 `plain-1`)→ PATCH 值 `sec-2` 读回正确 → secret→text(值存活 `sec-2`)→ type+value 合并 patch 成 secret(`sec-3` x3 恒定)→ 切换后 list 仍掩码。
- **T3 校验矩阵** 13/15 PASS,2 FAIL(即上述 issue):key 小写/数字开头/带横杠/带空格/空/缺失/256 字符 全 400;type bogus/123 → 500(FAIL);value 数值/对象 → 400 `Variable value must be a string`;value 65537 → 400;边界 key=255 字符 200、value=65536 字符 200;同 base 重名 400 `already exists in this base`;跨 base 同 key 200 合法。
- **T4 不可变/404/隔离** PASS:PATCH 改 key → 400 `Variable key cannot be changed. Delete and recreate`;GET/DELETE 不存在 id → 404;跨 base GET/PATCH/DELETE 变量 → 404×3,且 PATCH 未篡改原值。
- **T5 并发同 key** PASS:5 线程同 key 并发 POST → codes=[200,400,400,400,400](1 成 4×400,DB unique constraint 兜底生效),库内恰 1 行。
- **T6 删 base 零残留** PASS:base3 预置 text+secret 2 行 → admin DELETE base 200 → `uv pg8000` 直查 `nocodb-dev@qnap.elf-balance.ts.net`:`SELECT ... WHERE base_id='plw2mn5s5bf3d2l'` → **0 行**(R2 softDelete 清理修复生效);sanity:存活 base1 同表 9 行可查,证实查对表。
- **T7 权限** PASS(实测,非读码):admin 将 f05r3a 在 base1 降权 editor → list/create/patch/delete 全 **403**;再降 viewer → 全 **403**;恢复 creator 正常。与 `acl.ts` 读码一致(baseVariable* 仅 creator/owner,editor/viewer 无 include)。
- **T8 缓存一致性** PASS:text 连续 4 轮 PATCH→GET 即时新值(c2/c3/c4/c5);secret PATCH 值 → GET 立即 2 次恒 `s-c1`。

## 附注(非本路 issue,报 orchestrator)

- 多路互踩:f01e2e@ce-ee.local 共享回落号被并行路 signin 轮换 token_version,本路 admin token 两度 401(须 signin+操作原子化);专用账号 f05r3a 全程无此问题,建议后续各路强制专用号 + 回落号仅瞬时使用。
- base 删除 ACL:base 级 creator 被 `acl.ts:637-640` exclude `baseDelete`(owner-only,上游语义),本路经 super admin 删 base,非 fork 缺陷。
- 勘误:初判「路径 b 寄居 base1」系误读——`/users` full 模式枚举 org 全量用户,roles=None 即非成员;f05r3b 未实际加入。
- 清理完成:base1/base2/base3 均 DELETE 200;PG 终验 `nc_base_variables` 中本路 3 个 base_id 与 `F05R3A%` key 均 0 行(表内余 6 行属他路在用资源,未动)。临时凭证文件已删。
