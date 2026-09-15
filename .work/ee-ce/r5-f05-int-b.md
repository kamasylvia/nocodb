# r5-f05-int-b.md — F05 第 5 轮收敛确认 · 集成测试-对抗面（第 2 路）

日期：2026-09-12。账号 f05r5b@ce-ee.local（signup 成功；baseCreate 403 → 回落 f01e2e 建 base + invite f05r5b 为 base viewer，顺带构成 403 矩阵素材）。后端 127.0.0.1:8080 未重启。DB 面 uv pg8000 连 qnap.elf-balance.ts.net:5432/nocodb-dev（Infisical KDL dev 运行时注入，未落盘）。

## PASS

- **T1 create/update description 校验回归 — PASS**（8/8）
  create：desc={x:1}→400、desc=123→400、desc="hello"→200（回读一致）、desc=null→200。
  update：desc={x:1}→400、desc=42→400、desc="updated"→200、desc=null→200 且已清空。
- **T2 缓存守卫 — PASS**（5/5 API）
  secret GET×5 恒 `s3cret-v1`（无双解密空串回归，R2 fix 保持有效）；list/GET 交替×5：list 恒 mask、GET 恒解密明文；PATCH→`rotated-v2` 后 GET×3 恒新值。
- **T3 加密状态机四步三面 — PASS**（API+DB+行为三面）
  step1 create(secret)：API 面 list 掩蔽 / DB 面 `U2FsdGVkX1…` 密文（44B）/ GET 面解密明文。
  step2 rotate：DB 密文更新且 ≠新明文 ≠旧密文；GET 新明文。
  step3 flip secret→text：DB 落明文、GET 可读；flip back to secret：DB 重新加密。
  全库扫 7 个已知明文（enc-plain-A1/B2/C3、s3cret-v1、rotated-v2、del-sec-plain、echo-plain-99）at-rest 全 0 命中；全部 F05R5B secret 行密文-only。
- **T4 非法输入矩阵 — PASS**（31/31 全 400）
  key 轴 9 项（缺失/空/数字/对象/小写/首位数字/含空格/含横杠/256 字符）；value 轴 5 项（数字/对象/数组/布尔/64KB+1）；type 轴 4 项（未知串/数字/对象/大小写敏感枚举 `SECRET`）；description 轴 4 项（对象/数字/数组/布尔）。
  PATCH 侧 7 项全 400：type wrongtype/数字、value 对象/数字、desc 对象、空 body（Nothing to update）、key 不可变。
- **T5 PATCH 语义 — PASS**（7/7）
  value:null → `''`（text 行与 secret 行各验）；desc-only PATCH 不动 value；secret 行 value 写、desc 写、value:null 清均 200 不误拒（加密 key 在位）。
- **T6 删 base 零残留 + 并发同 key — PASS**
  并发 8 线程同 key create：恰 1×200 + 7×400（unique 违约回落 400 非 500），DB 恰 1 行。
  删 base×4（含 2 变量 base、跨 run 3 个 base 终清理）：pg8000 复验 `nc_base_variables` 按 base_id 与按 key 全 0 残留。
  归因注记（非产品）：过程中一次查到 `F05R5B_SEC_CACHE` 残留 1 行，定位为本路 run1#1 脚本中断（list 响应解析 AttributeError）致清理未执行的测试垃圾（行属已中断 run 的 base `p8v6hvqjp785lbp`）；产品删除路径多处实证零残留。
- **T7 权限 401/403 矩阵 — PASS**（12/12）
  401×4：无 token list/create、无效签名 token、空 token。
  403：base-level viewer create/patch/delete/get 全 403 且无值泄露（get 亦 403）。
  跨 base 混淆：正确 vid 配错误 baseId 的 GET/PATCH → 404（getVariableWithBaseCheck 生效，无跨 base 泄露）。
  观察：signup 直发的 org token 对 baseCreate 报 403 "No Access"（viewer 默认无建库权）——行为合理，与任务预设「signup 403 回落」一致。

## 观察项（不构成 error，语义判定）

1. `create` 响应回显 secret 明文 value（单变量 GET 同样返回明文，仅 list mask）。语义判定：create 回显的是请求方刚提交、本已知晓的值，无新增信息泄露；单变量 GET 明文是 `base-variables.service.ts` 注释声明的有意设计（「decrypted value is only served by the single-variable get」），与 list 掩蔽形成双通道。不判 error。
2. 环境（非产品）：共享回落账号 f01e2e 的 signin 会 bump token_version，使并行会审路持有的旧 token 全部失效（本路清理阶段实测 401 一次，re-signin 恢复）。建议后续轮各路建自己的回落账号，或协调回落账号 signin 时机。

## 证据

- API 91 checks（run1 68 + run2 7 + DB 16），0 产品 FAIL。
- 明细：`/Volumes/UNITEK/Documents/Development/nocodb/.work/ee-ce/f05r5b_run1_out.json`、`f05r5b_run2_out.json`、`f05r5b_t3db_out.json`；脚本 `f05r5b_run1.py` / `f05r5b_run2.py` / `f05r5b_t3db.py`。
- 资源已清理：3 个 f05r5b base 全删（200×3），`nc_base_variables` 中 F05R5B% 行 = 0。

## 裁决结论

**PASS — 0 error**。7 项对抗收敛全过：校验回归、缓存守卫、加密状态机三面、非法输入矩阵、PATCH 语义、零残留+并发、权限矩阵均无产品缺陷；2 条观察项均为设计语义或测试环境归因，不触发修复闸门。
