# r8-f07-lane1 — F07 Manage Snapshots 第 8 轮收敛(int + rev)

账号说明:专用账号 f07r8a@ce-ee.local 登录 400(不存在),按预案回落 f01e2e@ce-ee.local。所有资源前缀 f07r8a_,测后已清理(live base API 删 + 残留行/schema/测试用户 DB 硬删;他路 f07r8a_l3 系列 5 行未动)。DB 直查均为 nocodb-dev(qnap.elf-balance.ts.net)。

## int(全实测)

1. **快照全生命周期** — PASS
   - create → 200,status=processing(id snapriigbbjndi2vki / snapqphblvtu90lc9p)
   - 轮询 GET → completed;DB 副本行 deleted=false、status=''
   - 副本表数 1=1,records 逐行一致 [('row0',0),('row1',1),('row2',2)]
   - restore → 200,等异步 job 完成后:产物 live、title=`f07r8a_src2 (restored)`、records 3 行一致
   - delete snapshot → 200;GET → 404;DB registry 0 行 + 副本 deleted=true
2. **R7 修复回归(长标题)** — PASS
   - 源 title 131 字符(API 上限 150,150 时 create base 本身 400,属上游校验非 F07)
   - create snapshot → 200(不 400);DB 副本 title len=150(截断生效,前缀 32 字符 + 131 > 150 触发截断路径)
   - completed;restore → 200,产物 title len=142 ≤150、live
3. **删源 base 连带清理(cleanupByBaseIdWithCopies)** — PASS
   - 源(2 个 completed 快照)DELETE → 200
   - DB:nc_snapshots 该 base_id 行数=0;两个副本 base deleted=true;源行 deleted=true
4. **副本不存在** — PASS
   - completed 后 DB 置副本 deleted=true → GET 派生 status=error → restore 400(`not ready for restore (status: error)`)
   - 该状态下 DELETE snapshot → 200(registry 0);GET → 404
5. **校验/互斥/隔离/角色** — PASS
   - title 非 string(12345)→ 400 `must be a string`;513 字符 → 400 `exceeds 512`;合法 title → 200 原样落库
   - processing 互斥(修正测法:副本 base 行 status='job' 模拟 job in-flight):GET 派生 processing → create 400 `Another snapshot is still being created`;restore 同期 400;status 复原后 GET 自愈 completed。注:首轮用「DB 直插孤儿 processing 行」测得 200,系测试方法缺陷(孤儿行会被 deriveStatus 自愈为 error 且缓存 list 不可见),非产品问题,修正后 PASS
   - 跨 base 隔离:snapshotId 属 base A,经 base B 的 URL get/delete/restore → 全 404 `Snapshot not found`
   - editor 403:新建用户 f07r8a_ed(signup 200)+ DB 授 base 级 editor,list/create/delete 全 403 ERR_FORBIDDEN(acl.ts L274-277 creator+ 段,实测生效)

## rev(代码终审)

- **unified deriveStatus**(base-snapshots.service.ts:222):终态/非终态统一重推导,cache-free;副本 null→error、'job'→probe 先/超时 15min 后 error、否则 completed;restore 侧 `?? snapshot.status` 兜底正确 — 确认
- **getCopyBaseRow RootScopes.WORKSPACE**(:260):metaGet2(workspace_id, RootScopes.WORKSPACE, PROJECT) + deleted 探测,int-2/4 DB 变更即时可见,实证无缓存屏蔽 — 确认
- **ensureCopyExists**(:123):restore 在 derive completed 后二次探测,窗口期被删兜底 400 且状态落 error,不泄漏内部 id 404 — 确认
- **cleanupByBaseIdWithCopies**(BaseSnapshot.ts:182):逐副本 Base.softDelete(catch 吞缺失)+ deleteByBaseId;副本 softDelete 触发自身 cleanup 为空集,无递归风险;Base.softDelete(:458)与 Base.delete(:711)双钩位均在 — 确认
- **删快照守卫**(:204):副本行缺失跳过 softDelete 直接删登记行,不 500 — 实测确认
- **title 截断**:副本 `Snapshot <ts> of <base>`.slice(0,150)、restore `<orig> (restored)`.slice(0,150);nc_bases_v2.title 列宽 150,registry title 校验 512 == nc_snapshots.title 列宽 512(DB 实查一致) — 确认
- **ACL**:baseSnapshotList/Create/Restore/Delete 注册于 creator+ 段(acl.ts:274),controller 五路由齐挂 @Acl — 确认
- **洞**:无(未发现带 API 可达链的缺陷)。已知已声明残留:mutex 为 check-then-insert,多实例部署下跨实例互斥靠 DB 可见性,代码注释已声明 residual risk(单实例缓存语义正确,本轮修正测法实证单实例生效)

## rev 实跑门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0,0 输出
- `npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed

## 裁决

PASS
