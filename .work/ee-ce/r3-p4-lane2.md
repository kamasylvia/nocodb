# F09 P4 R3 — lane 2 报告(修复回归独立审查)

**结论:PASS / 0 error + 2 minor**

审查基线 = 840c4218aa(R2 修复批,HEAD);:8080 pid 38535(启动 01:41:12)运行 `~/.nocodb-run` dist(dist mtime 01:34:28,双条件通过;dist 内 R2 修复特征串命中 ×2)。账号前缀 `f09p4r3l2-*`(api/ed/ui/noa @review.local),camoufox session `f09p4r3l2`(已关闭),UI/API 账号分离。

## 1. R3 重点一:v3 LTAR 通道守卫(R2 lane3 E1 修复回归)——闭口

### 静态核验(840c4218aa)

- diff = `BaseModelSqlv2.assertLinkWriteAllowed` private→public(`BaseModelSqlv2.ts:6597`)+ `LTARColsUpdater.updateForColumn` 入口加同族守卫(`ltar-cols-updater.ts:219-233`,`model.synced → prohibitedSyncTableOperation`,位于 checkPermission 与 addOrRemoveLinks 之前)。
- 调用图闭合:`updateLTARCol` 唯一调用点 = v3 `nestedLink`(`data-v3.service.ts:1600-1603`);v3 `nestedUnlink` → `dataTableService.nestedUnlink` → `baseModel.removeLinks`(R1 守卫);`addOrRemoveLinks` 全仓直调 4 处 —— `BaseModelSqlv2.ts:8935/8955/8978`(addLinks/removeLinks/reorderLink,R1 五入口守卫之内)+ `ltar-cols-updater.ts:247`(updateForColumn,新守卫)。无残余绕过。
- 引擎通道:`table-sync.processor.ts` junction 写全为 `execAndParse(dbDriver(...).insert/delete)`(`:890/928/961/972/1014`),不经守卫方法 → 引擎不受守卫影响,无需 bypass flag。

### 活体(全绿)

| # | 断言 | 实测 |
|---|---|---|
| 1 | editor v3 `POST /api/v3/data/:base/:mirror/links/:col/:rowId` 注入 | **422** `ERR_SYNC_TABLE_OPERATION_PROHIBITED`(R2 症状 200/201 不复现) |
| 2 | editor v3 DELETE 解除真实配对 | **422**(同族文案) |
| 3 | owner v3 POST/DELETE on mirror | **422**(守卫角色无关) |
| 4 | owner v2 addLinks / editor v2 removeLinks(alias 漏斗) | **422 / 422** |
| 5 | 注入尝试后 junction 配对 | **不变**(a1-Lk1=[b1,b2] 原样;Lk2=[b3] 与源一致) |
| 6 | owner v3 对**非 synced 源表** link 写 | **200**(守卫不误伤合法路径) |
| 7 | 引擎 raw-knex 通道 | 源 relink/unlink realtime **2 秒级跟随**(t+2s 出现/清零),守卫零影响 |

## 2. R3 重点二:P1-P4 全矩阵站位(活体)

- **三层构建(双 link 共享 shadow)**:源 ta 带 Lk1/Lk2(mm→同 tb),selected_fields 建同步 → 主镜像(synced=true)+ **单一共享 shadow**(两 link 列 `fk_related_model_id` 同指一个 shadow)+ junction;shadow 4 行。
- **realtime 传播**:源 relink/unlink → 镜像 junction 2 秒级收敛(§1#7)。
- **updateSync link 级联**:keep PATCH(无 selected_fields)→ 200,三层不拆;加标量列(Notes)+ 删 Lk2 一并 PATCH → 200 → resync 后 Notes **真实进数**(a1=复核 "n1")、Lk2 列删、shadow 因 Lk1 仍引用而存活(引用计数)、junction 配对保留(2);`null` → 200,Lk2 列恢复且配对回填([b3],与源一致);`[]` → **400**("selectedFields must be a non-empty array or null")。
- **mark_deleted 两档一致**:incremental 删源行 → 镜像行自默认视图退场(标记);full-resync(sweep)后 0 行硬退场;两档收敛一致。
- **paste**:paste+link(驼峰显式点名 Lk1)→ **400** "Fields cannot be synced (unsupported or unknown): Lk1"(sourceSchema 不列 link);paste 全字段(缺省 null)→ **400** "Linked fields cannot be synced from a pasted shared view…"(:1027 安全裁定文案);paste 纯标量(驼峰 ["Title"])→ **200** + manual `sync-now` → active + 4 行 + 零 link 列。
- **AUTO 双档**:realtime(主 sync)与 manual(paste-scalar,sync-now 拉数)两档建链与拉数均通。
- **ACL**:editor PATCH/DELETE/CREATE sync → **403 ×3**;editor source-schema → 403(fail-closed)。
- **E1 六格**:R2 修复批未触 `assertSourceReadAccess`/loadSource 层(`git show 840c4218aa --stat`:仅 BaseModelSqlv2 两文件 + .work 脚本/文档)——静态核对无回归面;活体 spot:noa(DST owner + SRC 显式 no-access)source-schema → 403(ws-level no-access 在 ACL 层先拦,fail-closed 方向,非 E1 404 格前提)。六格全矩阵历轮(R5/R6/R9-R11)多次 pass,本轮未完整复测(见未核验)。
- **UI 活体**(camoufox,截图 `/tmp/f09p4r3l2/zh-delete-dialog.png`):
  - **editor 卡 gate**:ed 打开镜像表 → `New record` 按钮 **[disabled]**;owner 同表同样 disabled=true(synced 行写 gate 角色无关)。
  - **树菜单 + 新鲜度三态**:镜像表 context 菜单全项(status=Synced table / Sync now / Pause sync / Convert to regular table / Delete sync);**Pause → API status=paused → 不刷新重开菜单 = Paused + Resume sync;Resume → active**(M2 翻转语义保持)。
  - **删除流**:Delete sync → 确认弹窗(标题"删除同步"+ 表名引用 + 取消/删除同步),本轮取消,真删走清理阶段 API。
  - **zh-Hans**:`nocodb-gui-v2.lang=zh-Hans` 后全 UI 中文化;树菜单全中文(同步表/立即同步/暂停同步/转换为普通表/删除同步)、确认弹窗全中文——zh-Hans 键落位且渲染正确。
  - **向导三层:未复现入口**(ui-base 空态无 Data Sync/Import 卡,Overview 卡未渲染)——列入未核验;R2 修复批前端零改动,向导在 R1/R2 两轮活体 pass。

## 3. 质量门

- `tsc --noEmit`:**exit 0**。
- jest Fork 桶(table-syncs 34 + baseVariableValidators 12 + uniqueConstraintHelpers 14):**60/60,exit 0**。
- vitest URL 门(test/formula-url-xss.test.ts):**5/5 passed**(首跑 beforeAll hook 10s 超时系本机负载抖动,`--hookTimeout 60000` 通过——AGENTS 已载该抖动特性,非断言失败)。

## 4. Minor(均为 R2 已列遗留,非新引入)

- **M1(R2 lane3 M1 未闭)**:`msg.warning.syncPasteLinkUnsupported` 仍为死键(en/zh-Hans json 落位、nc-gui 零引用);paste 拒绝实际文案为后端硬编码英文两处(`table-syncs.service.ts:1007` unknown/unsupported、`:1027` Linked fields cannot be synced),zh-Hans 用户在该拒绝路径只见英文。功能不受影响。
- **M2(R2 lane3 M2 未闭 + 本轮新增观察)**:
  - a) spec 仍无 v3 通道用例(table-syncs.Fork.spec.ts 守卫 4 例 = addLinks/addChild/audit-only/普通表;removeChild/removeLinks/reorderLink/v3 updateForColumn 零断言)。本轮活体已实覆 v3 通道,但 spec 回归防线缺口仍在。
  - b) **createSync 不认蛇形 `selected_fields`**:service 只解构驼峰 `selectedFields`(`:836-847`;updateSync 有蛇形归一 `:1323-1324`,createSync 无)→ 蛇形被静默忽略并按 null(全字段)处理。实测:paste 模式蛇形纯标量请求撞 ":1027" 400,驼峰同请求 200。前端实发驼峰(`CreateNewSync.vue:155`)故主路径无恙;属 API 健壮性缺口。

## 5. 观察(不计 error/minor)

- 排查过程中多次 link 计数读数 "2" 为**读数伪影**(field-not-found 错误对象 dict 的 len=2),复核原始响应后排除,产品无涉。
- paste 模式 syncableLinks 含 mm **反向自动列**(子表回显列):paste 全字段(null)在反向列存在时触发 ":1027" 拒绝,行为符合"paste 不带 link"安全裁定。
- mirror 列被 updateSync 删除后重建(null 恢复)生成**新 colId**,旧 colId 引用 404——级联语义自洽。

## 6. 未核验(环境/范围限制,非「通过」)

1. UI 向导三层活体(入口在本环境未复现;修复批前端零改动,历史 R1/R2 两轮活体 pass)。
2. E1 六格全矩阵活体(需 ws 角色铺垫;修复批未涉该层,静态核对无变化)。
3. editor 树菜单逐项可见性(editor 侧以 API ACL 403 ×3 + New record disabled 佐证;树菜单以 owner 视角验证)。

## 7. 纪律

只读审查(工作树无源码改动);未构建/重启/pkill/未跑 dev-backend*.sh;无 psql;未读他路 R3 报告(任务书指定对照 R2 文件除外);测试 base ×4(src/dst/ui-base/ui-src)及随附 sync/share view/映射全部删除,**残留 NONE**(trash 平台语义);测试账号 f09p4r3l2-{api,ed,ui,noa}@review.local 留档(历史轮同惯例);凭证零落盘;camoufox session 已关闭、语言态已还原。
