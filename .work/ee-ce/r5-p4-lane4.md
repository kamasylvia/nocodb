# F09 P4 R5 — lane 4(引擎重点路)报告

**结论:PASS / 0 error + 0 minor**
(R4 lane5 E1 共享 shadow drop 腿修复 b4849136e1 活体回归全过:删单条/全删/幂等重试三腿零 404 零部分拆毁零残留;junction 孤儿 sweep 活体收敛;P1-P3 标量引擎站位无回归;三质量门全绿。)

审查基线 = b4849136e1(R4 修复批)。运行时双条件核验:`~/.nocodb-run/.../dist/main.js` mtime 2026-09-22 03:57 **<** :8080 进程(pid 76261)启动 04:06:36 ✓;运行 dist 特征串命中(`F09 P4-R4` ×4、`convergence sweep` ×1)→ :8080 运行的确含 R4 修复。账号 `f09p4r5l4-{owner,editor}`(引擎路全 API,UI 路未涉);camoufox session `f09p4r5l4` 未启用(纯 API 引擎验证)。脚本:`f09p4r5l4-{setup,reset-dst,run1,run2,run2b}.sh` + `f09p4r5l4-dbcheck.mjs`(node+pg 只读核验 nocodb-dev,凭证运行时经 Infisical KDL 注入,库名硬编码)。

## 1. 共享 shadow drop 腿修复活体(R4 lane5 E1,run1:26 PASS / 0 FAIL)

- **三层建成**:双 mm→T2(Ns,Ns2)+ mm→T3(Nr)同选 createSync → API roles = 2 linked_shadow + 3 junction;**DB 层**(nc_table_sync_mappings)junction 行 = 3;junction 配对回填 1/1/1;T2 shadow 行回填 2。
- **腿 A 删单条**(PATCH 移除 Ns,保留 Ns2/Nr)→ **200,404 零复现**;Ns2 junction 表 200 + 配对 1;T2 共享 shadow 保留 + T3 shadow 完好(shadow=2);Ns junction mapping 行清(junction 3→2,API 与 DB 双层核验);镜像 link 列 Ns 删、Ns2/Nr 完好。
- **腿 B 一条 PATCH 全删**(Ns2+Nr)→ **200**(R4 症状 404 ERR_FIELD_NOT_FOUND 零复现);roles=[main];2 junction + 2 shadow 表全 404;镜像 link 列零残留;DB 层 junction+shadow mapping 行零残留。
- **幂等收敛**:null 重建三层(2S+3J)→ **重复同全删 PATCH ×2 全 200** → 仍 roles=[main] 零复活、DB 零残留——重试幂等收敛达成。

## 2. junction 孤儿 sweep 活体(run2 A 段 + run2b)

- **keep-only gate**(P4-R4 设计约束「仅真 drop 后 sweep」):同 selection PATCH → 200 且零动作(last_synced_at 不变 = 无 resync,mapping 行不变)——gate 不误触发 ✓。
- **孤儿制造(合法路径)**:外部 columnDelete 删源 T1 的 Ns 列(镜像 mirror system 列 API 守卫拒删 400,守卫正确)→ PATCH null → Ns 镜像列按标量路径删(link 列 3→2)、双 shadow 保留;**Ns junction mapping 行即时残留 = 已知遗留「源 link 列删除孤儿」的现形态**(sweep gate `droppedLinkSrcColIds.size` 仅在 link 分支添加,源列删除走标量分支不触发——遗留维持,勿重复报,但见 M 观察 1)。
- **孤儿收敛活体(run2b)**:后续 PATCH 真 link drop(Nr 落选)→ sweep 触发 → **孤儿 Ns + Nr junction mapping 行一并清(3→1)**、消失 junction 表 404;存活 Ns2 junction 表 200 + 配对与源侧一致(resync 按源侧 2 对回填 2 行,数据自洽)——**中断/遗留孤儿经下一次 drop PATCH 幂等收敛** ✓(spec 第三用例 mid-loop failure retry 的活体等价)。
- **DB 层核验**:run1 全删后 nc_table_sync_mappings junction+shadow 行 = 0;run2b 收敛后 = 1(仅存活 link)。

## 3. P1-P3 标量引擎站位回归(run2 B 段,全过)

1. **标量 drop/add**:Qty 落选 → mirror Qty 列删;加回 → 列回建 + 值回填(p2→2)。
2. **v3 LTAR 通道守卫**:owner/editor 对 sync 镜像 `POST/DELETE /api/v3/data/{base}/{model}/links/{col}/{row}` → **422 ERR_SYNC_TABLE_OPERATION_PROHIBITED**(错误体文案在);**合法路径不误伤**:源表 v3 POST/DELETE link = 200(bare-pk body)、v3 GET mirror 读路径 200。
3. **ACL**:editor 对 list/create/resync/detach/delete 五端点全 **403**;editor PATCH mirror records → 400(守卫链禁入)+ 数据未被写动(读回核验)。
4. **两档删除一致**:源删 p3 后 sync2(delete 档)resync → mirror 行删;sync3(mark_deleted 档)resync → p3 行保留 + **RemoteDeleted=true**。
5. **AUTO realtime**:realtime sync 源插行 → ~秒级自动传播 mirror(无手动 resync,40s 窗口内)。
6. **引擎通道**:源加配对 → resync → junction 配对 1→2(raw-knex 通道正常)。

## 4. R4 小修验证

- processor catch-up 头注释:src `modules/jobs/jobs/table-sync/table-sync.processor.ts` 及全仓 grep **"WITHOUT sweep" 零残留**;现注释正确描述「incremental 无 id 回落 full pass(upsert + disappearance sweep)——sweep is safe and required there」✓。

## 质量门

- `npx tsc --noEmit`(packages/nocodb):**exit 0**。
- `npx jest --testPathPattern 'Fork'`:**63/63,3 suites 全过**(R4 修复批新增 shared-shadow drop convergence 3 用例在列)。
- Vite URL 门:`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`:**5/5 过**。

## M 系列(minor:0)

无新增。两条观察(非判定项,均已实测定位语义):

1. **(观察)sweep gate 未覆盖「源 link 列删除」孤儿路径**:`droppedLinkSrcColIds` 仅在 drop 循环 link 分支添加,源列已删时走标量分支 → 当次 PATCH 不清其 junction mapping(表本身被 columnDelete 级联删,残留的只是 registration 行)。属遗留「源 link 列删除孤儿」的精确定义域,**且已被后续任一 drop PATCH 的 sweep 幂等收敛(run2b 活体)**——非永久僵尸,不构成 error;遗留判定维持。
2. **(观察)合法 v3 源 link POST 的 body 契约为 bare-pk 数组**(`[1]`),对象数组(`[{"Id":1}]`)报 422 `Invalid value '[object Object]' for type 'integer'`——审查脚本首测踩坑所致的假信号,与 sync 守卫无关;守卫只拦 synced mirror,源表 200 通达。

## 环境瞬态与工具噪音(不计项)

- run1 首遍 5 个 FAIL 均为审查脚本自身缺陷(zsh 词切分 / link 列 title 断言预期错),修正后重跑 26 PASS;run2 首遍 6 个 FAIL 归因:源删 body 格式错(`[3]` vs `[{"Id":3}]`,2 项)、resync 读数竞态未等 job 完成(2 项,run2b 以 last_synced_at 轮询修正后全过)、断言预期错(2 项)。全部非产品缺陷。
- reset-dst.sh 的 dst 重建一次失败(环境瞬态),未影响活体(run1 直接在原 dst base 上以第二个 sync 完成,标题自动加后缀)。

## 清理核验

- 测试 sync ×5、src/dst base 均 DELETE 200;API bases 列表 `f09p4r5l4*` 计数 = **0**(清零核验);DB 层无物理表残留于活表视图(7 行 meta + 7 物理表属 base soft-delete trash 语义,由平台 trash GC(`nc_202604200002_trash_cleanup_due_at`)延迟清理,历轮同标准)。
- 测试账号 `f09p4r5l4-{owner,editor}` 保留(无删除用户 API,全前缀可辨,历轮惯例)。
- DB 凭证仅运行时经 Infisical 注入环境变量,未写入任何 git 跟踪文件;`f09p4r5l4-*` 脚本在 `.work/` 白名单内,口令为本地 dev 一次性测试口令。

## 纪律

只读审查(`git status -- packages/`:**零改动**);未构建/未重启/未 pkill/未跑 `dev-backend*.sh`;无 psql、未提权(DB 层核验走仓库自带 node+pg 只读 SELECT,应用账号,nocodb-dev 库);隔离未读他路 R5 报告(对照材料限任务书指定:r4/r3 lane-prompt、r4-p4-lane5;`f09p4r4-fix-selftest.sh` 为修复批 commit 内流程件,仅参考 API 调用形态,活体设计独立)。

## 判定依据

- R4 lane5 E1 三症状(404 中断 / 部分拆毁 / 重试后永久孤儿 junction)在本轮三类活体(删单条 / 全删 / 幂等重试 ×2)中**零复现**,两阶段 drop + refcount + 收敛 sweep 的静态逻辑与活体行为一致。
- P1-P3 标量引擎(v3 守卫 / ACL / 两档删除 / AUTO / 引擎通道 / 标量 drop-add)站位全过,无回归信号。
