# r3-f01-rev-c — 交叉面复审(第 5 路, R3)

裁决: **PASS**(本次改动面 0 issue;1 条预存观察项归属上游, 非 F01 引入)

## 1. 安全

- **diff 无凭证**:全 diff 逐行过目(11 文件), 无 password/token/PAT/secret 字面量。dev-backend.sh 凭证运行时 Infisical 拉取不落盘;f01-e2e.sh 的 `PASS="F01e2e!pass1"` 为本地 dev 一次性测试账号, 仓根 AGENTS.md §3.1 明确许可, 且 .work/ 不进 git。
- **value 回显面最终核**:uniqueConstraintErrorHandler.ts 三处 `UniqueConstraintViolationError({value})` 的 value 来源仅:① PG/MySQL/Oracle 错误 detail 中 `Key (col)=(value)` 提取——唯一约束冲突语义保证该值 == 调用者本次提交值, 无他人数据;② insertData(调用者 payload);③ findDuplicateColumnByQuery 返回的也是 payload 值;④ 'unknown' 兜底。fieldName 为本表列 title/form label(触发前提是对该表的写权限)。API-only JSON, 无存储型 XSS 面、无跨租户/跨表泄露。**PASS**。

## 2. 一致性

- **[CE-EE] 标记全覆盖**:diff 全部 11 处改动块均有标记(gitignore/useEeConfig/EditOrAdd/jest.config x2/BaseModelSqlv2 x4/MysqlClient/handler x4/helpers/columns.service x4/tables.service);两个未跟踪新文件(Fork.spec.ts、nc-gui test)各含 `[CE-EE]` 头注。✓
- **isEeUI 未翻转**:packages/nc-gui/utils/ncUtils.ts:1 `isEeUI = false` 原样;diff 未触及该文件。✓
- **.gitignore 生效**:`git check-ignore -v` 实测 `.work/`(.gitignore:139)、`packages/noco-integrations/packages/`(.gitignore:141)均命中。✓
- **Api.ts 不在改动列表**:git status 全列(11 M + 2 ??)无 Api.ts。✓

## 3. 测试基建(实测)

- `cd packages/nocodb && npx jest --listTests | wc -l` = **1**(仅 uniqueConstraintHelpers.Fork.spec.ts)。✓
- jest 全量:**13/13 passed**(1 suite, 14.9s)。✓
- nc-gui vitest fork 文件:**8/8 passed**(unique-constraint-helpers.test.ts)。✓

## 4. 运行时红线(实测)

- dev-backend.sh:PGHOST=`qnap.elf-balance.ts.net`、DBNAME=`nocodb-dev`(:9 注释严禁 nocodb), 无其它 host/db 硬编码。✓
- f01-e2e.sh:BASE_URL=`http://127.0.0.1:8080`(本机 dev server → nocodb-dev)。✓
- 运行中进程实测 `ps eww`:rspack(pid 74959)与 dist/main.js(pid 92571)env `NC_DB=pg://qnap.elf-balance.ts.net:5432?u=postgres&p=***&d=nocodb-dev`, 指向 nocodb-dev。✓
- **trap 清理读码核**:`trap cleanup EXIT` 于脚本头部(:21)注册, 覆盖全部退出路径:① 正常路径 :92 显式 DELETE 后 EXIT trap 再 DELETE(404 被 `|| true` 静默, 幂等);② fail() exit 1 → trap 触发, 此时 TOKEN/CREATED_BASE 已设者被清理;③ 早期失败(登录前)CREATED_BASE 空, `${CREATED_BASE:-}` 守卫跳过;④ set -e 中途命令失败 → trap 触发。`:26` 的 `[ "$i" = 120 ] && fail` 为 AND-OR list 短路, zsh/bash 下不触发 errexit 误退。✓

## 5. 文档同步

- GOAL-STATE.md:更新时间 2026-09-12、"R2 裁决完成, R3 会审进行中"、LOCK=active、计数 0/3——与 git diff 实际吻合(R2 三项修复全在 diff:errorString 扫描移除、_pkey/constraintName 守卫 x2、bulkUpdateAll 接 handler;R1 批次 normalizeUniqueConstraintFlag 三入口/UUID NC-DB gate/MysqlClient/updateByPk+bulkUpdate catch/.gitignore/isolatedModules 均在 diff)。✓
- .work/TODO.md:F01 未勾(未 pass, 状态正确)。✓
- 仓根 AGENTS.md(?? 未跟踪, 待收尾 commit):§3 测试描述含 Fork 桶、§3.1 凭证红线、§4 .work 不提交——与现状一致, 无凭证。✓

## 6. 脚本幂等(读码判定)

- f01-e2e.sh:base/table 用 epoch 秒命名, 每轮自建自清(显式 DELETE + trap 兜底, `|| true` 幂等);重复运行 signup 已存在走 signin 分支, 不残留资源。残留边角仅 kill -9 硬杀(trap 不触发)与 base 建成但响应解析失败(:46 fail 时 CREATED_BASE 未及赋值)两类, 概率极低且非脚本逻辑缺陷, 不计 issue。✓

## 观察项(非 issue, 归属上游)

- packages/nc-gui/test/pwa-self-destroying.test.ts:全量 vitest 时该文件 transform 失败(`Failed to resolve import "../pwa.config"`)。实测归属:上游 commit 867b407ba2 引入的已跟踪文件, 工作区无改动;`pwa.config` 上游本就未跟踪/本地不存在。**非 F01 diff 引入, 建议不阻塞 F01 计数**;fork 相关 vitest(8/8)与 jest(13/13)全绿。
