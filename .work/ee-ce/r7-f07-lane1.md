# r7-f07-lane1(第 7 轮,独立第 1 路:int + rev)

## 裁决:PASS

---

## rev 实跑门

- `npx tsc --noEmit`:exit 0,0 错误(log 0 字节)
- `npx jest baseVariableValidators --runInBand --forceExit`:**12/12 passed**

## rev(service/model/controller 终审)

逐点核对,全部通过:

1. **unified deriveStatus 重推导**(base-snapshots.service.ts L220-252):所有状态(含 terminal)每次读均 cache-free 重探;副本行缺失→error;status='job'→先探后超时(15min);其余→completed。transient 误标自愈、purge 副本降级 error,逻辑自洽。restore 的 `deriveStatus() ?? snapshot.status` 兜底正确(error 行不再 500)。
2. **getCopyBaseRow RootScopes.WORKSPACE**(L258-273):经 meta.service.ts contextCondition(L266-293)核实,生成 `WHERE fk_workspace_id=<ws> AND id=<snapshotBaseId>`,R4 修复语义正确;`row.deleted===true` 判 null 覆盖软删副本。
3. **ensureCopyExists**(L121-136):restore 前强校验副本存在,缺失→行标 error + 400,无内部 id 泄漏。
4. **cleanupByBaseIdWithCopies 动态 import**(BaseSnapshot.ts L188):Base.ts(models/index barrel)→BaseSnapshot.ts 无静态回边,无循环;`try/catch` 容忍副本已失;递归链有限(副本自身快照行为空时终止);实测删源 base 路径完整跑通(T8)。
5. **删快照守卫**(service L185-218):副本存在才 softDelete,行必删;副本已失仍 200(实测 T3e)。
6. **/nc/ 跳转**:Snapshots.vue `navigateTo(/nc/${restoredBaseId})`,与上游 getBaseUrl 一致。
7. 权限面:后端 acl.ts 四个 `baseSnapshot*` 挂 creator+;前端 lib/acl.ts 同步;`blockSnapshots=false` 仅解本 gate,未全局翻转 isEeUI。
8. BaseSnapshot model:insert/update extractProps 白名单(防 base_id 越权改);缓存 object 先物化后 appendToList(R1 修复在位);metaGet2 base_id 条件支撑跨 base 404。

**找洞:无**(无 API 可达链的洞;create 互斥 check-then-insert 竞态为代码注释明示的 residual risk,不构成新问题)。

## int(全实测,http://127.0.0.1:8080,nocodb-dev)

账号说明:专用 f07r7a@ce-ee.local 登录被拒(Invalid credentials),按指示回落 f01e2e@ce-ee.local(super)。环境注意:dev 后端 rspack 热编译重启使 JWT secret 重置、旧 token 间歇 401(非 F07 代码问题,重登解决)。

源 base `pte730sspuns1ja`(f07r7a_src_1789233216),表 f07r7a_tbl 3 行(alpha/10, beta/20, gamma(x)/30)。

| # | 项 | 结果 |
|---|---|---|
| T1a/b | restore 产物 base 含表+3 行数据一致 | PASS |
| T2a | DELETE snapshot → 200 | PASS |
| T2b | 删后 GET snapshot → 404 | PASS |
| T2c | 副本 base API → 404(DB deleted=true) | PASS |
| T3a/b | 建快照 processing→completed | PASS |
| T3c | DB 置副本 deleted=true 后 GET 派生 **error** | PASS |
| T3d | restore 该快照 → 400 | PASS |
| T3e/f | 删该孤儿快照 → 200,行消失 404 | PASS |
| T4a/b | title=123 / title=["x"] → 400(原 500 已修) | PASS |
| T4c/d | title 513 → 400;title 512 边界 → 接受 | PASS |
| T5 | DB 摆 status='job'+processing → create → **400 "still being created"**(互斥生效;脚本首轮断言键名 msg/message 笔误已复现实测确认) | PASS |
| T6a/b/c | 跨 base GET/restore/DELETE 快照 → 全 404 | PASS |
| T7a-e | editor 邀请成功;editor GET/POST/restore/DELETE 快照 → 全 403 | PASS |
| T8a-c | 新 base 建快照 completed 后删源 base → 200 | PASS |
| T8d | pg8000 直查:nc_snapshots 该 base_id 行 = **0** | PASS |
| T8e | pg8000 直查:快照副本 base deleted = **true** | PASS |
| T9a | snap3 删除 → 200 | PASS |

另:对已软删源 base POST snapshots → 404 ERR_BASE_NOT_FOUND(无越权路径)。

## 清理

- API 删除:f07r7a_src、restored base、f07r7a_other、f07r7a_del、repro 快照(全部软删入 trash,平台语义)
- DB 复核:f07r7a 相关 nc_snapshots 行 0 残留;所有 f07r7a base deleted=true
- 孤儿 schema:DROP CASCADE 8 个(pte730sspuns1ja/p8virqf8xyfsktu/pkncba43q5q3xlw/ppu1hvdwtkil5ui/pjsoxak89spc9lt/pj8zmbm75xywgov/pu3i4jp606ik54r/pyvkdxque8gy0vm),复查 remaining=[]
- 凭证临时文件已删(.work/ee-ce/f07r7a_dbenv)

## issues 列表

无。
