# r4-f01-int-b.md — R4 集成测试·对抗面（独立第 2 路）

- 日期: 2026-09-12
- 环境: dev server http://127.0.0.1:8080（ nocodb-dev ）；资源前缀 `f01r4b_`；测试账号 f01e2e@ce-ee.local
- 方法: 全 API 实测（curl）+ pg8000 直查 `nocodb-dev`（host qnap.elf-balance.ts.net，Infisical KDL DB_*；未触 `nocodb` 生产库）
- 表: `f01r4b_a`（Title/U1*/U2*/Num*，*=unique）、`f01r4b_c`（Name/A1*/A2*/A3* Number unique/Tag，5 列 3 unique）
- PG 唯一索引形态（实测）: 单列 unique → `CREATE UNIQUE INDEX ... USING btree ("<col>") WHERE ((__nc_deleted IS NULL) OR (__nc_deleted = false))`（软删感知 partial index；空串因非 NULL 正常参与唯一性）

## 结论: PASS

各项证据:

### 1. handler 加固回归 — PASS
- 1a 重复插入 U1=dup1 → HTTP 400 `{"error":"FIELD_UNIQUE_CONSTRAINT_VIOLATION","fieldName":"U1","value":"dup1"}`
- 1b Number 列插 "abc23505xyz"（含 23505 字样的非法值，R2 回归）→ HTTP 400 `{"error":"ERR_DATABASE_OP_FAILED","message":"Invalid value 'abc23505xyz' for type 'bigint'","code":"22P02"}`，**非 FIELD_UNIQUE** — R2 结构化 code 判定生效
- 1c 多 unique 列归因 = PG 实际检出约束：撞 U1 → fieldName=U1/value=v1；撞 U2 → fieldName=U2/value=v2（提取自 PG detail `Key (col)=(val)`）
- 1d 空串重复（R3 回归）：先插 `{"U1":"","U2":"e1"}`，再插 `{"U1":"","U2":"e2"}` → HTTP 400 FIELD_UNIQUE，`value:""`（非 "unknown"）；第二子例 `{"U1":"","U2":"e1"}` 重复（两列同时撞）→ 归因 U1/value=""（PG 实际检出），value 均非 unknown

### 2. bulk insert — PASS
- 2a 批内重复 `[b1,b2,b1]` → HTTP 400 FIELD_UNIQUE U1/b1；count 插入前后 3→3，整批回滚
- 2b 撞已存 `[b3, v1(已存在)]` → HTTP 400 FIELD_UNIQUE U1/v1；count 3→3
- 2c `?undo=true` + 撞已存 `[u1,u2,v1]` → HTTP 400 FIELD_UNIQUE U1/v1；count 3→3（u1/u2 未落库）；对照 `?undo=true` 干净批 → HTTP 200 count 3→4
- 2d 并发 5 同值：HTTP 200×1（Id=18）+ HTTP 400 FIELD_UNIQUE×4（value=conc1）；`(U1,eq,conc1)` 查得 1 行

### 3. bulkUpdateAll — PASS
- 端点 PATCH `/api/v1/db/data/bulk/noco/{baseId}/{tableId}/all?where=`
- 3a where=(U2,like,t3_%) 设 U1=v1（已存在）→ HTTP 400 FIELD_UNIQUE U1/v1；3 行 U1 保持 m1/m2/m3（行完整）
- 3b 自值更新 where=(U2,eq,t3_a) 设 U1=m1 → HTTP 200 count=1（PG 同值更新合法）
- 3c 折叠撞值（3 行设同 U1=same_u）→ HTTP 400 FIELD_UNIQUE U1/same_u；行完整性保持（单条 UPDATE 原子）；注：PG intra-op 重复无 `Key()=` detail，handler 回落 payload 归因，error code/字段/值正确，仅 message 措辞仍为 "already exists"（语义无碍，非违反）
- 3d 3 行设同 U2=t3x → HTTP 400 FIELD_UNIQUE U2/t3x，行不变

### 4. 列生命周期 + PG 索引核验 — PASS
- 加列 U3(unique) → meta.unique=true + PG 出现 `uk_pdojdcebmobq4ih_<tid>_<cid>` unique partial index ON ("U3")
- 改名 U3→U3r（PATCH /api/v2/meta/columns/{colId}）→ meta title=U3r/column_name=U3；PG 索引仍挂物理列 "U3" 不变；新 title 下重复插入 → HTTP 400 FIELD_UNIQUE `fieldName:"U3r"`（form-label 感知）
- 删列 → HTTP 200；PG `uk_...` 索引消失；meta unique 仅剩 [U1,U2,Num]
- 全程 U1/U2/Num 的 `f01r4b_a_{U1,U2,Num}_key` 索引不受扰动

### 5. 组合边界 — PASS
- 5a 单条插入两 unique 列同时撞（A1=x1, A2=y2）→ HTTP 400 FIELD_UNIQUE A1/x1；4 次重复归因稳定 = PG 实际检出（A1 索引先检）
- 5b 260 字符值：插入 HTTP 200；重复 → HTTP 400 FIELD_UNIQUE，value 完整 260 字符
- 5c emoji 值 `🚀🔥emoji`：插入 HTTP 200；重复 → HTTP 400 FIELD_UNIQUE A2/`🚀🔥emoji`（Unicode 完整）
- 5d 改一列引发他列约束：PATCH `{Id:1,A2:"y2"}`（撞行2）→ HTTP 400 FIELD_UNIQUE A2/y2，行1 不变；A3(Number) 撞 → FIELD_UNIQUE A3/200；自值更新 → HTTP 200
- 5e bulkUpdate 两行互换 A1（瞬态 intra-op 冲突）→ HTTP 400 FIELD_UNIQUE A1/x2，两行均保持原值（行为记录：换位需应用层规避，DB 层正确拦截）

### 6. 状态一致性（meta.unique vs PG，抽样 3 处）— PASS
- 样本1 `f01r4b_a`（经 add/rename/delete 全生命周期后）: meta [U1,U2,Num] == PG unique 索引列 [Num,U1,U2]
- 样本2 `f01r4b_c`: meta [A1,A2,A3] == PG [A1,A2,A3]
- 样本3 `f01r4b_c` 加删 D1 循环: ADD 后 meta/PG 同为 [A1,A2,A3,D1]；DEL 后同回 [A1,A2,A3] — 逐步一致

## 清理
- DELETE /api/v2/meta/bases/{bid} → 200（软删，trash 保留期设计）；孤儿 schema `pdojdcebmobq4ih` 已 DROP CASCADE；PG `f01r4b%` 表清零。测试中间产物目录 `.work/ee-ce/.tmp/r4b/`。

## 备注（非违反，仅记录）
- 测试初期 401 根因：JWT 须用 `xc-auth` 头（`xc-token` 为 API token 专用）；且每 signin 轮换 token_version（users.service.ts:751 single-session enforcement），并行 5 路共用同账号会互踢——已改用 base API token 脱离。属测试方法，非被测功能缺陷。
- dev server 中途被并行路触发 rspack 重编译一次（~80s 不可用），等待恢复后重跑，无影响。
