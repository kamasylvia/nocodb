# F09 P4 R5 — lane 3（安全审计重点路）报告

**结论：PASS / 0 error + 0 minor**

（R4 error 修复 b4849136e1 三腿活体回归全过；P4 站位继承同规格复跑全过；安全五焦点（v3/v2 LTAR 通道守卫、paste 凭据面含共享 shadow drop 后凭据残留复查、响应凭据剥离、detach ACL、七 tap 防环含 bulkInsert/bulkRestore）静态 + 活体双证全绿；质量门 tsc 0 + jest Fork 63/63 + Vite URL 5/5。本轮 0 error，清洁轮。）

审查基线 = b4849136e1（R4 修复批，两阶段共享 shadow drop + junction 收敛 sweep + 幂等 drop）。dist 双条件核验：dist mtime 2026-09-22 03:57 < :8080 进程启动 04:06:36（pid 76261）✓；dist 特征串命中：`F09 P4-R4` ×4、`convergence sweep` ×1、`manage the links in the source table` ×2、`prohibitedSyncTableOperation` ×7（与源码 7 处守卫调用点一一对应：ltar-cols-updater ×1 + BaseModelSqlv2 ×5 + forms.service ×1）→ :8080 运行的确是含 R4 修复的 dist。账号 `f09p4r5l3-{owner,editor,uied}`（API/UI 分离）；camoufox session `f09p4r5l3`。

## 一、R4 E1 修复回归（活体，run1，38 PASS）

共享 shadow 环境（源主表双 mm link 同指 T2 → 1S+2J、配对回填 1/1）：

1. **腿1 删单条 link**：PATCH `selectedFields:[Title,Ns2]` → 200；共享 shadow 保留、落选 junction mapping 清（余 1）、存活配对 = 1、shadow 表 200、镜像列 Ns 删/Ns2 留。**另一 link 三层完好 + 404/部分拆毁/孤儿零复现**（R4 lane5 E1 三症状全消）。
2. **腿1b 加回**：仍 1S+2J 复用共享 shadow + 配对回填 1/1。
3. **腿2 E1 精确触发**：一条 PATCH 删全部 link → **200**（旧代码 404 ERR_FIELD_NOT_FOUND）→ roles=[main] 零孤儿、两 junction 表 404、shadow 表 404、镜像 link 列全删。
4. **腿3 中途失败重试收敛**：重放同 PATCH 200 幂等（roles 恒 main）；`null` 重建 → 二轮全删 → 再次 200 + roles=[main] + 表全删净，收敛可重复零残留。
5. **凭据残留复查（本路重点）**：createSync / getSync / listSyncs / 删单条后 / 二轮全删后 / paste 全程，全部响应 `..|objects|keys[]` 扫描 **source_uuid / source_password_hash / password 零命中**。凭据仅存活于 main mapping 行（EE 持久凭据语义），dropShadowForRelated 与收敛 sweep 只删 shadow/junction mapping 行（本就无凭据字段），无凭据落出 main mapping 的通道。
6. R4 小修：processor catch-up 头注释已核（`catch-up runs the full pass WITH the disappearance sweep`，无 "WITHOUT sweep" 残留）。

## 二、P4 站位继承（活体，run2/run2c/run2d/run2e）

1. **v3 通道守卫**（精确路由 `/api/v3/data/{base}/{model}/links/{col}/{row}`）：editor 与 owner 双角色对 synced 镜像 link 列 POST/DELETE → **422 `ERR_SYNC_TABLE_OPERATION_PROHIBITED`**（"manage the links in the source table" 文案精确命中）；拦截后 junction 配对不变；owner 对源表 v2 link 写 200/201 合法不误伤。
2. **v2 通道守卫**：editor/owner 对镜像行 bulk delete → **422 prohibited**（守卫与角色无关，角色无关性是防环与写禁语义的关键属性）；editor 六端点（list/create/resync/detach/delete/freeze）全 **403**。
3. **updateSync 级联**：run1 腿1/腿1b/腿2 即级联活体（keep 类 PATCH 三层保持、drop 类全级联 + full-resync 投放收敛）。
4. **AUTO realtime**：realtime 档 sync 创建成功（AUTO 解锁）；源标量插入秒级传播 mirror；link 配对变更经 `'link'` tap → junction 配对 1→2 自动回填（无手动 resync）。**防环稳定观察**：回 active 后静置 10s，status 稳定 active、配对恒 2，无 resync 风暴（镜像写未再触发分发）。
5. **窗口 delete 收敛（全量 pass 含 sweep）**：源删带配对行 → manual resync → mirror 行删 + junction 孤儿清（配对 2→1），二次 resync 幂等。
6. **mark_deleted 两档一致**：mark_deleted sync 建成（悬挂对不复制，配对=1）；源删行 → mirror 保行 + `RemoteDeleted=true` + junction 配对清零——与 delete 档「两档一致清配对」语义一致。
7. **detach**：owner detach 200 → SYNC 登记删（getSync 404）、mirror synced=false 转正、readonly 解锁后可写；editor detach 403（见 2）。detach 三表转正语义（main/shadow/junction 全转正）由 `Model.updateSynced(false)` 循环 + P4 实现批活体维持。
8. **UI 活体**（camoufox f09p4r5l3，uied）：editor 打开 synced 镜像 grid → **「New record」按钮 `disabled: true`**（DOM 证据，截图 `ui-shots-f09p4r5l3/01-editor-mirror-grid-newrecord-disabled.png`）；editor 按上游路由直送 grid（Overview 为 creator-only），无同步管理入口。

## 三、安全五焦点静态审查（源码逐点）

1. **七 tap 防环**：`BaseModelSqlv2.ts` 八处 tap 调用点全数核对——afterInsert L5644 / afterBulkInsert L5697 / afterBulkRestore L5909（restore 归 insert 档）/ afterUpdate L6149 / afterBulkUpdate L6005 / afterDelete L5788 / afterBulkDelete L5830 / updateLastModified `'link'` L9215。**全部**带 `!this.model.synced` 守卫 + try/catch 吞错 + fire-and-forget；junction 引擎写走 raw-knex 不过 hook，shadow/junction 为 synced=true 恒不 tap——防环闭环无缺口（含新增 bulkInsert/bulkRestore 两处）。
2. **v3/v2 通道守卫**：v3 唯一写入口 `LTARColsUpdater.updateForColumn`（ltar-cols-updater.ts L224）guard 在场；v2 面 `assertLinkWriteAllowed`（public，L6600）被 addChild/removeChild/批量路径 5 处调用（L6657/7053/8925/8945/8968）+ beforeInsert/beforeBulkInsert/beforeDelete/beforeBulkDelete 4 处行守卫；dist 特征串 ×7 与源码调用点计数一致（无缺失、无旁路）。引擎 junction 写 raw-knex 天然绕开但写的是自身合法产物，无 bypass 标志需求。
3. **paste 凭据面**：凭据持久化仅 main mapping（insertMainMapping L1276-1279，uuid + bcrypt hash，永不明文）；R4 修复新增路径（两阶段 drop、收敛 sweep、幂等 catch）不新增任何凭据读写；paste+link 400 拒收语义维持（share credential 单视图暴露不升级）。
4. **响应凭据剥离**：全部响应漏斗 `getSync`（createSync/updateSync/freeze/resume/delete 均返回 `this.getSync(...)`）+ listSyncs 独立剥离；blacklist delete `source_uuid`/`source_password_hash` 双字段；resync 响应 `{id,name,status}` 三键收敛（活体验证 keys 恰等、零 JWT 回显）。
5. **detach ACL**：路由 `POST .../table-syncs/:id/detach` → `@Acl('tableSyncDelete')`（utils/acl.ts L325，creator-only 块）；服务层 Syncing 态拒 detach；活体 editor 403 / owner 200 双证。

## 四、质量门

- `npx tsc --noEmit`（packages/nocodb）：**exit 0**。
- `npx jest --testPathPattern 'Fork'`：**63/63，3 suites 全过**（table-syncs.Fork.spec.ts 含 R4 新增 3 条共享 shadow 回归用例，本轮实测通过）。
- Vite URL 门：`npx vitest run test/formula-url-xss.test.ts --config test/vite.config.ts`：**5/5 过**。
  - 环境注记（非缺陷）：默认 forks pool 本轮多次 `Failed to start forks worker ... Timeout waiting for worker to respond`（worker 60s 启动超时，与 R4 轮同命令不同命）；归因 = 外置盘（UNITEK）冷缓存下 worker 进程拉起读盘超时（GOAL-STATE 已载外置盘冷读问题）。`--pool=threads` + `--hookTimeout 240000` 后稳定 5/5。属运行环境漂移，非被测代码问题，不判项。

## 五、M 系列（minor：0）

无新增。已知遗留项（R4 任务书清单：i18n 死键 / spec 无 v3 通道用例 / createSync 蛇形 selected_fields / 源 link 列删除孤儿 / bulkUpdateAll 不 tap / paste resync 不复验 hash / afterBulkRestore CE 无调用方）本轮未涉，维持原判定不重复报。

两条非判定观察（记录不判项）：
- dropMirrorLinkColumn 幂等 catch 用消息正则 `/not[\s_-]?found|404/i` 吸收 404 族——任何 message 含 "not found" 的错误（如 BASE_NOT_FOUND 类）也会被吸收进「继续清 mapping」分支。当前收敛语义下安全（mapping 清理方向正确），仅记正则宽匹配观察。
- 收敛 sweep 对 tableDelete 失败仍无条件删登记行——极端连续失败下可能留下无登记的孤儿 junction 表（base 树内可见可删，非静默数据面问题）。best-effort 设计意图明确。

## 六、未覆盖（环境/范围限制，非「通过」）

1. v3 PATCH 镜像标量 400 readonly（P1 既有语义）本轮未单独复跑——R4 lane5 已锁，本轮 v3 面以 links 守卫为主。
2. editor Overview 页 DOM 直证（上游按角色跳过该页；以 ACL 静态闭环 + editor 六端点 403 活体替代，与 R4 lane5 同口径）。
3. 测试账号删除：无删除用户 API，`f09p4r5l3-{owner,editor,uied}` 保留（全前缀可辨，历轮同惯例）。
4. 源 junction 表悬挂对探查依赖系统表 records API，仅做了计数级核对（B3：源删行 200 后引擎侧收敛以镜像/junction 终态判定）。

## 七、纪律

只读审查（`git status`：packages/ 零改动；仅新增 `.work/ee-ce/f09p4r5l3-*.sh` 脚本、本报告与 `ui-shots-f09p4r5l3/` 截图）；未构建/未重启/未 pkill/未跑 `dev-backend*.sh`（bootstrap 提权用 f01e2e 走 `PATCH /api/v1/users/:userId` + workspace 邀请 API，未触任何进程）；无 psql、未提全局 super；隔离未读他路 R5 报告（对照材料限任务书指定：r5/r4 lane-prompt、r4-p4-lane5、修复批 diff 与 f09p4r4-fix-selftest.sh）。测试数据清零：全实例 `f09p4r5l3*` base 计数 = **0**（super admin 侧全量核验，含历轮探针 `probe_l3*`）；camoufox session `f09p4r5l3` 已 close；口令仅存 `.work` 白名单脚本（历轮惯例），无凭证写入 git 跟踪文件。
