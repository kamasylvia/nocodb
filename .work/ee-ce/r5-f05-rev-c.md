# r5-f05-rev-c.md — 第 5 路交叉面复审(F05 第 5 轮收敛确认)

## PASS

实测证据(2026-09-12):

1. 安全终审(secret 全链路实测,连 nocodb-dev,qnap.elf-balance.ts.net:5432,凭证 Infisical KDL DB_*)
   - API 创建 secret 变量(REV_C_SECRET)→ 200
   - DB 直查(uv pg8000)nc_base_variables.value = `U2FsdGVkX1/...`(CryptoJS AES 密文,明文未落库)
   - 列表响应掩码(value=MASKED);单读解密稳定(连续两次返回明文一致,缓存双解密回归通过)
   - 删 base 后 DB rows=0(BaseVariable.deleteByBaseId 清理路径实测生效)
   - key 不入 git:NC_CONNECTION_ENCRYPT_KEY 仅存在于 .gitignore:139 覆盖的 .work/ee-ce/dev-backend.sh;git grep/git diff 无 secret 值与 dev key 泄漏;临时凭证文件已清
2. 一致性
   - [CE-EE] 标记覆盖全部 15 个改动代码文件(lang JSON 不可注释,豁免)
   - Api.ts / isEeUI / packages/sdk:git status 与 diff 零涉及
   - GOAL-STATE.md(L5/L7/L10)与 .work/TODO.md(L8)均同步"F05 R5 会审进行中"
3. 测试基建(实跑)
   - npx tsc --noEmit(packages/nocodb)exit 0
   - jest 26/26(baseVariableValidators.Fork 12 + uniqueConstraintHelpers.Fork 14)
   - vitest 10/10(base-variables-acl 2 + unique-constraint-helpers 8)
   - backend.log 无 F05 相关 error(exception/fail/variable/encrypt grep 零命中)
4. commit 前清单(对照 git status)
   - 12 tracked 修改 + 6 untracked(base-variables.controller.ts / base-variables.service.ts / baseVariableValidators.ts + .Fork.spec.ts / base-variables-acl.test.ts / vitest.config.ts[R4 新增])全部属 F05 面,无多余文件
   - lang en/zh-Hans JSON 有效且无同层重复 key(labels.key 与 placeholder.key 分属不同段)
