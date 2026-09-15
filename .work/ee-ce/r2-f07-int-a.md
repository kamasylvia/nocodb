# r2-f07-int-a.md — F07 Snapshots 第 2 轮 集成测试(正向+边界) 第 1 路

日期: 2026-09-12。后端 http://127.0.0.1:8080(nocodb-dev)。账号: f07r2a@ce-ee.local 登录 400 Invalid credentials(账号未建),按预案回落 f01e2e@ce-ee.local。DB 直查 pg8000 → nocodb-dev(qnap.elf-balance.ts.net:5432)。

## 逐项结论

1. T1 快照全生命周期 — PASS
   - create → 200 `status=processing`(snapqjsdeuyoedh56o / 副本 p115zql5twq139a)
   - 轮询 → `completed`(秒级,远小于 10-40s)
   - 副本 base GET 200,title=`Snapshot 2026-09-12T03-24-09 of f07r2a_src`,表 `f07r2a_t1` 在,3 行数据完整 `[row0,0][row1,1][row2,2]`
   - restore → 200 新 base `pkazw6koltcd0lk` title=`f07r2a_src (restored)`,表+3 行完整(restore 为异步 job,表列表需短暂轮询后出现)
   - delete snapshot → 200 body=true;副本 base 随即 404;list 中该行消失
2. T2 R1 修复回归(删「副本已不存在」的快照) — PASS
   - create→completed 后 API DELETE 副本 base(t2.delCopyBase 200,GET 副本 404)→ DELETE snapshot → **200 body=true**(R1 守卫生效,不 500);list 中行消失
3. T3 title 校验 — PASS
   - `{"title":123}` → 400 `Snapshot title must be a string`
   - `{"title":{"a":1}}` → 400 同上
   - 600 字符 → 400 `Snapshot title exceeds 512 characters limit`
   - 缺省 → 200,title=`Snapshot 2026-09-12T03-24-58` 默认格式成立
   - 三次非法请求后 list count 不变(无脏行泄漏)
4. T4 processing 互斥 — PASS
   - 快照 processing 期间再 create → 400 `Another snapshot is still being created. Try again once it completes`;首个随后 completed
5. T5 跨 base 隔离 + 并发 — PASS(隔离部分)
   - A base 的快照经 B base URL GET → 404 `Snapshot not found`;DELETE → 404;正确 base + 不存在 id → 404
   - PATCH `/api/v2/meta/bases/{id}/snapshots/{id}` → 404 Cannot PATCH(路由不存在,与 API 清单一致)
6. T5b 并发同 base 双 create — 行为记录(非判罚)
   - 同时发 2 个 create → **双双 200**(snap7qr184jem467kf、snapw4256rzt1zi43y),均 completed、均可独立 delete,无损坏
   - 与 `packages/nocodb/src/services/base-snapshots.service.ts:40-47` 代码注释声明的残余风险一致("mutex is check-then-insert and racy by design — worst case two copies get created (no corruption); documented residual risk")。按 TASK 口径仅记录;若裁决认为须硬互斥,需 DB 约束或行锁,当前实现自洽
7. T6 删源 base 后 nc_snapshots 清理(Base.delete/softDelete 钩子) — **FAIL**
   - 实测:源 base `pkazw6koltcd0lk` 上 create→completed(nc_snapshots 1 行,DB 确认)→ API DELETE base → 200,DB 确认 `nc_bases_v2.deleted=true` → **nc_snapshots 该 base 行仍 = 1**(清零失败)
   - 根因(静态+运行时一致):`BaseSnapshot.deleteByBaseId` 已定义于 `packages/nocodb/src/models/BaseSnapshot.ts:158-175` 但全仓无任何调用点;`Base.delete`(`src/models/Base.ts:606`)与 `Base.softDelete`(`src/models/Base.ts:401`)均未调用(对比同文件 BaseVariable 同款钩子:`Base.ts` softDelete 段 `await BaseVariable.deleteByBaseId(...)`、delete 段同款,F05 R1/R2 已修,F07 漏接)
   - 建议:在 `Base.softDelete` 与 `Base.delete` 各加 `await BaseSnapshot.deleteByBaseId(context, baseId, ncMeta);`(import 自 `~/models`)。附带影响:源 base 删除后其快照副本 base 也一并成孤儿(本测中副本 `psrqqo6itnnta1j` 需 DB 手动软删清理)

## 清理

- API 软删测试 bases(f07r2a_src、2 个 restored);T6 残留快照行 + 副本 base 经 nocodb-dev DB 手动清理
- 终验:nc_snapshots 测试相关行 = 0;`deleted=false` 的 f07r2a base = 0;凭证临时文件已删
- 测试脚本存 `.work/ee-ce/f07r2a_*.py`(lib/setup/t1/t2/t3t4/t5/t6/cleanup/dbq)

## 裁决

issues 列表(1 项实际违反):

- `packages/nocodb/src/models/Base.ts:606`(Base.delete)与 `:401`(Base.softDelete):问题:删除/软删 base 不清理 nc_snapshots 行(T6 实测:软删后残留 1 行,FIXME 无任何调用点);建议:两函数内补 `await BaseSnapshot.deleteByBaseId(context, baseId, ncMeta);`,对齐 F05 BaseVariable 同款钩子

其余各项(T1/T2/T3/T4/T5/T5b 记录项)PASS。R1 五项修复(删守卫/title 校验/insert 缓存顺序/derive 超时/互斥 400)全部回归通过。
