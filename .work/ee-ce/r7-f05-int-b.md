# r7-f05-int-b — F05 Variables 集成测试·对抗面(第 2 路,第 7 轮最终收敛确认)

环境:后端 http://127.0.0.1:8080(nocodb-dev,qnap.elf-balance.ts.net:5432,pg8000 直查);
账号 f01e2e@ce-ee.local(creator,资源操作)/ f05r7b@ce-ee.local(viewer,权限面);
base `pe4ob4wwi6yvcdj`(f05r7b_adv_main)。0 error 轮。

## 结论:PASS

47 项断言全 PASS,0 FAIL。另含 2 项补充核查(stale-cache probe、DB 双查零残留)均符合预期。

## 分项证据(全部实测)

### 1. 缓存守卫 — PASS
- T1a secret GET×5:5 次单变量 GET value 恒定 `s3cret-VALUE-1`,无缓存 double-decrypt 退化(R2 修复保持)。
- T1b list/GET 交替×4:list 中 secret 的 `value`/`default_value` 恒被 mask(JSON 中字段消失),单 GET 明文恒定;交替无串扰。
- T1c PATCH 后 GET×3:PATCH value 后 3 次读恒定新值,缓存同步正确。
- 补充:删 base 后立即 GET 其 variables → 404(非 stale 200 列表),缓存面无残留。

### 2. 加密状态机四步三面核 — PASS
DB 面 = pg8000 直查 `nc_base_variables`;缓存/API 面 = 连续 GET 恒定 + list mask。
- step1 create secret:DB `value = U2FsdGVk…`(CryptoJS AES OpenSSL 前缀),无明文;API GET 明文正确。
- step2 PATCH value(secret 行):DB 重加密,新密文 ≠ 旧密文,无明文泄漏。
- step3 flip secret→text:DB 变明文,值 = 最后一次写入的明文(模型侧解密写回正确)。
- step4 flip text→secret:DB 重新变密文(`U2FsdGVk…`,无明文);API GET×3 明文恒定。
- 对照:plain 变量 DB 全程明文,未被误加密。

### 3. 非法输入矩阵四轴 + PATCH 语义 — PASS(全 23 项)
- key 轴(全 400):lower_case / 1START(数字开头)/ WITH-DASH / 空 / 256 字符超长 / 缺失。
- value 轴(全 400):对象 `{"a":1}`(绕过 64KB 检查的路已堵)/ 65537 字符超 64KB。
- type 轴(全 400):`"bogus"` / 数字 `123`。
- description 轴(400):对象 create 拒绝。
- 注入守卫:create 带 `base_id/order/default_value/inheritance` 全被白名单忽略,DB 实查 base_id 正确、order 自动、default_value 空。
- PATCH 语义:key 不可改 400;空体 400(Nothing to update);仅传同值 key 400;desc 对象 400;value 超 64KB 400;type 非法 400;`value:null` → 200 且清空为 ''(REST PATCH 语义);`description:null` → 200 清空;不存在 id → 404;跨 base 正向/反向 → 404。

### 4. 删 base 零残留 + 并发同 key — PASS
- 并发同 key:10 路并发 POST `F05R7B_RACE` → 恰 1×200 + 9×400(唯一约束竞态回落 400,非 500),list 中该 key 恰 1 行。
- 删 base 零残留:删 base(内含 1+ 变量)后,DB `nc_base_variables` 按 base_id 计数 0;最终按三个测试 base(f05r7b_adv / f05r7b_adv_main / f05r7b_adv_other)与已删 base id 双查均 0。
- 删后缓存一致性:主 base variables list 仍 200,未受 deepDel 误伤。

### 5. 权限 401/403 矩阵 — PASS(12 项)
- 无 token:list/get/post/patch/delete 全 401;垃圾 token → 401。
- viewer(f05r7b,org-level-viewer,未授权该 base):list/get/post/patch/delete 全 403(No Access)。
- creator:同面操作 200,ACL 通道正常。

## 清理
f05r7b_* base 全删(API 列表 0);DB 变量残留 0;测试账号保留(每轮复用)。

## 备注(非 issue)
- f01e2e 为共享账号:并行会审路signin 会旋转 token_version 使旧 token 401,本路测试一气呵成未受影响;建议后续轮各路使用独立 creator 账号以消除该干扰源。
- 首两轮脚本自身 curl 参数错位曾产生伪 000/伪 PASS,已修正并以修正后完整重跑结果为准(47/0)。
