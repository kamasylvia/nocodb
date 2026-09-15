# r6-f07-lane1 报告(第 1 路:集成测试 + 代码复审)

R6 收敛确认。`git diff` + status 全量审;后端 http://127.0.0.1:8080 实测(账号 f01e2e 回落 + f07r6a/f07r6a_ed 专用);pg8000 直查 nocodb-dev(qnap.elf-balance.ts.net,Infisical KDL 凭证)。测毕资源已清理(6 schema DROP、nc_snapshots 0 行、测试 base 软删)。

## int(集成实测)

1. **快照全生命周期** — PASS
   - POST snapshots → 200,status=processing(新增副本 base status='job')
   - GET 轮询 → completed(~6s)
   - 副本 DB 核验:独立 schema,`f07r6a_items` 3 行 / maxQty=3 与源一致,title `Snapshot <ts> of f07r6a_src`,deleted=false
   - POST restore → 200 `{base_id}`;新 base `f07r6a_src (restored)`,API records 3 行(row1-3)+ DB schema 3 行
   - DELETE snapshot → 200;副本 base DB deleted=true;GET 副本 → 404
2. **删源 base 回归(cleanupByBaseIdWithCopies)** — PASS
   - DELETE /api/v2/meta/bases/:id → 200(软删)
   - nc_snapshots WHERE base_id=源 → 0 行
   - 唯一存活副本连带软删(deleted=true);restored base / 无关 base 不受影响(deleted=false)
3. **副本缺失路径** — PASS
   - completed 后 DB 手动置副本 deleted=true → GET 派生 status=error → restore 400 `not ready (status: error)`
   - 删该快照(副本已不存在)→ 200,登记行移除
4. **校验/互斥/隔离/权限** — PASS
   - title 非.string(123)→ 400 `must be a string`;600 字符 → 400 `exceeds 512 characters`
   - processing 互斥:DB 置副本 status='job' 模拟长任务 → POST create → 400 `Another snapshot is still being created`(注:小 base 副本 ~6s 即 completed,自然窗口极短,互斥逻辑本身生效)
   - 跨 base 隔离:其它 base 路径下 list=[]、GET/restore/delete 全 404
   - editor 403:base editor 角色对 list/create 均 403(`baseSnapshotList`/`baseSnapshotCreate` 不在 Editor include)

## rev(代码终审)

- **unified deriveStatus 重推导**:所有状态(含 terminal)逐行 cache-free 重探(getCopyBaseRow 直查 meta);副本没了→error、job 卡 >15min→error、否则 completed;processing 存量自愈实测通过(mutex 测试后残留 'processing' 由后续 GET 重推导回 completed)。
- **getCopyBaseRow RootScopes.WORKSPACE**:metaGet2(ws, WORKSPACE, PROJECT, id) 经 contextCondition 验证——base_id===RootScopes.WORKSPACE 时 early return,条件为 `fk_workspace_id=ws AND id=:snapshotBaseId`,正确;误传普通 base_id 会 `WHERE id=base_id` 恒空,R4 修复成立。
- **ensureCopyExists**:completed 后副本消失竞态兜底(derived!=completed 主检查已覆盖主路径,此处为窄窗防御),置 error + 400,无 404 内部 id 泄漏。
- **cleanupByBaseIdWithCopies 动态 import**:BaseSnapshot 无静态依赖 Base(Base.ts→models/index→BaseSnapshot 单向),无环;运行时动态 import 已加载模块安全;逐副本 try/catch 吞副本已消失异常、行清理仍执行。回归实测通过。
- **删快照守卫**:副本在→Base.softDelete(避开 Base.delete first-source 守卫)、副本缺→跳过仅删行,两路径实测 200。
- **/nc/ 跳转**:Snapshots.vue `navigateTo(\`/nc/${restoredBaseId}\`)` 与上游 pages/projects/index/list.vue:15 同构,路由合法。
- **ACL**:后端 permissionScopes.base(creator+ 级联)+ 前端 ProjectRoles.CREATOR 块,EDITOR 两级均无;实测 editor 403 吻合。
- **cache 一致性**:BaseSnapshot.list 缓存键(prefix:ws:base_id:snapshot:<baseId>:list)与 deleteByBaseId deepDel 键逐段核对一致;insert 先 materialize 再 appendToList。
- **module/路由注册**:noco.module.ts controller+provider 注册;controller v1/v2 双路径与仓库惯例一致。
- **diff 内共享代码改动**:uniqueConstraintErrorHandler 正则 `[^)]+`→`.+`(PG DETAIL 单行 `Key (col)=(val)` 形态,greedy 捕获含 `)` 值,修复目的行为,无可达错误链);dataHelpers !base 守卫(纯防御);nuxt.config allowedHosts(dev-only,注释声明)。

**找洞**:无(有 API 可达链的洞未发现)。已知已声明残留:mutex check-then-insert 竞态(代码注释声明,最坏多建副本无损坏);list deriveStatus N+1 探针(meta 量级,非功能缺陷)。

## rev 实跑门

- `cd packages/nocodb && npx tsc --noEmit` → exit 0,无输出
- `npx jest baseVariableValidators --runInBand --forceExit` → 12/12 passed

## 裁决

**PASS**(int 全过 + rev 0 error + 实跑门双过)
