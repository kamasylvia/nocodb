# r6-f05-rev-c — F05 R6 第 5 路:交叉面复审(安全终审/一致性/测试基建/commit 清单)

隔离声明:未读任何 r*.md 历史报告;只读 TASK.md、仓根 AGENTS.md、源码、git 面。

## 实测证据(非引用)

1. **安全全链路(实跑,live :8080 → nocodb-dev)**
   - 建 base → POST secret 变量(key=R6C_SECRET, value=`R6C-plain-<ts>-x7Kq`)→ 200;
   - list 掩码:value 字段不存在(undefined)✅;单条 GET 解密回原明文 ✅;
   - uv pg8000(host=qnap.elf-balance.ts.net, db=`nocodb-dev`,`SELECT current_database()` 实证非生产库)查 `nc_base_variables`:该行 value=`U2FsdGVkX1…`(64 字符,CryptoJS 密文前缀),明文不在 value/default_value;全表扫描明文 marker 0 命中(除下述残留行)✅;
   - 删 base 行为学复验(新 base+secret→DELETE base 200→DB 查变量行 0 残留,R2 修复在当前运行构建上生效)✅;
   - key 不入 git:`git ls-files | xargs grep "dev-only-ce-ee-encrypt-key"` 0 命中;测试明文 marker 0 命中;`.work/` 已 gitignore(.gitignore:139);`DB_PASSWORD` 命中均为上游示例文档/键名引用,无真实凭证 ✅。
2. **测试基建(实跑)**
   - `packages/nocodb` `npx tsc --noEmit` → exit 0;
   - `pnpm test` → 2 suites,26/26 pass(exit 0);
   - `npx vitest run test/base-variables-acl.test.ts test/unique-constraint-helpers.test.ts` → 10/10 pass;
   - 全量 `npx vitest run` → 16 文件过,2 文件失败=pwa-self-destroying(transform 崩,import 已删 pwa.config)+formula-url-xss(文件级 :20 失败)= AGENTS §3.2 已记录上游噪音,非本 fork 引入。
3. **一致性**
   - Api.ts / nocodb-sdk / ncUtils.ts(`isEeUI=false`)零改动(git status 无记录)✅;
   - [CE-EE] 标记:15 个触碰代码文件全部含标记(1-10 处/文件);lang/*.json 无法携带注释(惯例豁免);AGENTS.md 为文档 ✅;
   - i18n 键 en/zh-Hans 双侧对齐(10 新键逐一核对 UI 引用)✅;
   - commit 面:12 M + 6 ?? 与 GOAL-STATE R5 记录的 12M+6?? 完全一致,无新文件混入/无遗漏;6 个未跟踪文件均可跟踪(无 ignore 误伤);diff/新文件无 console.*、debugger 残留 ✅。

## issues 列表(仅问题)

1. `.work/TODO.md:8: F05 行仍写「R4 裁决完成→R5 会审进行中」,GOAL-STATE 已推进到 R6(5/5 PASS→连击 1/3):状态源不同步,违反 TASK 验收「GOAL-STATE / TODO.md / 本文件状态同步」:R6 commit 前把 TODO.md F05 行同步到 R6 进行中(建议收尾时随归档一并更新至最终态)。
2. `nocodb-dev.nc_base_variables(id=bv0ektbw9msih1fb): 残留 secret 行 value='s3cr3t!' 明文,归属 base pwgjdxol0fv0gnc(f05_e2e_1789169685,deleted=true,2026-09-12 07:34 建):属 R2 孤儿清理修复生效前/加密 key 注入前留下的历史测试残留(当前构建实测新行皆密文、删 base 即清理,非现行代码缺陷):建议收尾时 `DELETE FROM nc_base_variables WHERE id='bv0ektbw9msih1fb'`(dev 库,复核后执行),保持「encrypted at rest」卫生。
3. (信息项,不阻塞)`packages/nc-gui` 全量 vitest exit 1 源于上述 2 个上游噪音文件:验收口径「vitest 10/10」以 fork 定向套件为准,已实测 10/10;维持 AGENTS §3.2 记录即可。

## 结论

F05 diff 面 0 代码 error;安全链路/一致性/测试基建实测全过。仅 2 个 commit 前流程项(TODO 同步、dev 库残留行清理)待收尾处理。
