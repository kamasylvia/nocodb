# r2-f01-rev-c.md — 第 5 路交叉面复审（R2）

## 1. 安全 — PASS

- 全 diff（9 tracked）+ 3 未跟踪文件过目：无任何真实凭证（DB 密码/PAT/token 值）。f01-e2e.sh 的 EMAIL/PASS 为本地 dev 一次性测试账号口令，AGENTS.md §3.1 明文允许写入 `.work` 测试脚本，合规。
- `handleUniqueConstraintError` value 回显面（updateByPk BaseModelSqlv2.ts:2897 / bulkUpdate :4641 新接入）：
  - value 来源仅两处：① PG 错误详情 `Key (col)=(value)`——unique 冲突语义下该值 == 调用者刚提交的值；② 调用者自己的 payload（insertData）。`findDuplicateColumnByQuery` 以调用者 value 为 WHERE 条件，不读取他人行内容。跨用户信息泄露 = 仅「该值已存在」推断，unique 约束固有语义，非新面。
  - 存储型注入：value 不落任何持久层（仅 HTTP 响应）；NestJS JSON 序列化，API-only JSON 无 HTML 上下文；前端 errorUtils.ts:76 仅布尔判断 + 文本插值渲染，未发现 v-html sink。
  - bulkUpdate `insertData: datas?.[0]` 与上游 bulkInsert（insert.ts:699 `datas?.[0]`）口径一致，非 fork 引入偏差。

## 2. 一致性 — PASS

- [CE-EE] 标记：9 个修改文件逐 hunk 核对，全部带标记；2 个新测试文件各含 [CE-EE] 头注。
- isEeUI：diff 零 hunk 触及 isEeUI；解 gate 为 blockUnique 单点 false（useEeConfig.ts:163），符合 AGENTS §5「逐功能解 gate」。
- .gitignore：`git check-ignore -v` 两路径均命中（.gitignore:139 .work/ / :141 packages/noco-integrations/packages/）。
- git status 无 packages/nocodb-sdk/src/lib/Api.ts ✓（R1 修复 #1 保持有效）。

## 3. 测试基建 — PASS

- `npx jest --listTests | wc -l` = 1（仅 uniqueConstraintHelpers.Fork.spec.ts）。
- Fork spec 实跑：13/13 pass（36.7s）。
- nc-gui vitest 实跑：test/unique-constraint-helpers.test.ts 8/8 pass（10.7s）。
- jest.config.js isolatedModules:true 注释与实际一致：ts-jest transform 级 isolatedModules = transpile-only（绕过 language service，无类型检查副作用）；类型检查确由 rspack 管线承担（ps 实见 ts-checker-rspack-plugin getIssuesWorker 进程在跑）。

## 4. 运行时红线 — PASS

- dev-backend.sh:7,9 `PGHOST="qnap.elf-balance.ts.net"` / `DBNAME="nocodb-dev"`（含「严禁用 nocodb（生产）」注释）。
- f01-e2e.sh:2 注释「连 nocodb-dev」；两脚本均无 `d=nocodb&` 生产库引用（grep 0 命中）。
- 运行中 rspack（PID 74959）`ps eww` env 实测：`NC_DB=pg://qnap.elf-balance.ts.net:5432?u=postgres&…&d=nocodb-dev` ✓（密码已遮蔽未回显）。
- logs/backend.log：Nest application successfully started（04:33/04:58/05:00 三次启动记录）。

## 5. 文档同步 — PASS

- AGENTS.md §3.2 坑列表逐条抽查与实际一致：nocodb-sdk 构建产物 build/main/index.js 存在；symlink packages/noco-integrations/packages/core → ../core 存在；:49 testRegex 描述 `(Integration|Source|Fork)\.spec\.ts$` 与 jest.config.js 实际一致；凭证红线措辞与 §3.1/§5 自洽。
- .work/TODO.md：F01 未勾选（未 pass 不勾，正确）；「待人工验证」节与状态自洽。
- GOAL-STATE.md：更新时间 2026-09-12 / R1 修复完成 / R2 会审 5 路运行中 / LOCK active / 计数 0/3——与 git diff 实际（R1 修复批次 1-8 全部在 diff 中可见）一致。
- 观察（不判违反）：AGENTS.md §1 表 F01 状态列仍「待做」。§4 已声明状态源为 GOAL-STATE（当前状态），§1 为暂定清单，工作流第 5 步（收尾）才更新；R2 未闭环中途改它反而形成双状态源。

## 6. 测试脚本健壮性 — 1 issue（读码判定）

- 成功路径幂等 ✓：`RUN_TS=$(date +%s)` 秒级命名 base/table，step 7 DELETE base；重复跑成功不残留。
- issues:
  - .work/ee-ce/f01-e2e.sh:12,81-82: `fail()` `exit 1` 直接退出，跳过 step 7 清理——step 4-6 任一回归触发 fail（恰是脚本存在的意义）时残留 base+table+记录于 nocodb-dev，且后续运行无清扫逻辑（时间戳命名不冲突，残留永不回收）: 建议 `trap 'curl -sS -X DELETE .../bases/$BASE_ID' EXIT`（BASE_ID 建成后置非空哨兵）或 ERR 分支清理
- 严重度：低。不阻塞 R2 裁决。

## 裁决

1 issue（f01-e2e.sh 失败路径残留 base，低严重度，建议修不强制）。其余 5 项全部 PASS。无必修 error。
