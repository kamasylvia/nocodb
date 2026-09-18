# F09 P2 R4 — lane 2(修复回归 + 全矩阵站位路)报告

**结论:PASS — 0 error + 0 minor**

R3 四项修复(基线 253c3b6ee5)逐一活体回归全过;P1+P2 全矩阵站位 API + UI 双面零缺陷。质量门三绿。

基线核验:HEAD 2316318dad(仅 dispatch chore,代码 = 253c3b6ee5);:8080 = pid 96879(3:51AM 启动)运行 dist(mtime 03:00,进程晚于 dist);dist P2+R1 特征 5/5 命中(sourceInputMode×4 / sharedViewUrl×5 / passwordProtected×7 / bypassSyncedFieldGuard×4 / detach×22)。前端 :3000 nuxt dev HMR 即当前源码。

## 0. 环境与账号

- f01e2e@ 仅作基建(建 4 base + 邀请),lane 资源全 `f09p2r4l2-` 前缀:SRC(源表 3 列 3 行,grid allow_sync+密码)/ D1(api owner)/ D2(ui owner + editor)/ D3(空 base,editor)
- 账号 f09p2r4l2-api / -ui / -e(UI/API 分离);camoufox session `f09p2r4l2` 专属,全程未动 default
- **基建账号竞争观察**:f01e2e token_version 被并行 lane 的 signin 持续轮换,跨 lane 共享 xc-auth 秒级互踢——lane 脚本改用「signin 即用 + retry 窗口」模式绕开(非产品问题,流程备忘:多 lane 并行时共享基建账号的 xc-auth 不可缓存)

## 1. R4 重点 1|editor Overview 卡 —— 过(修复活体)

- **editor 开空 base D3 → 「NocoDB Sync」卡不可见**(`editor-d3-home.png`):动作面板全空(No tables,Create New Table / Import Data / NocoDB Sync / Connect External Data 四卡全无文本命中)。R3 E1 修复(Overview.vue:134 `isUIAllowed('sourceCreate')` gate)活体回归 ✓
- **creator 仍可见可用**:ui owner 开 D2 → 卡可见 → 向导三步全通 → Create sync 200(`creator-d2-home.png` / `wizard-step0-hashurl.png`)

## 2. R4 重点 2|hash 形共享 URL —— 过(API + UI 双面)

源视图 uuid=5741daf4-…,hash 形 `http://localhost:3000/#/nc/grid/<uuid>`:

| 断言 | 结果 |
|---|---|
| resolveLink hashURL 无密码 → `{passwordProtected:true}` 仅此一字段(零坐标/零标题泄露) | PASS |
| resolveLink hashURL 对密码 → 200 全量坐标(sourceTableId==SRC) | PASS |
| resolveLink hashURL 错密码 → 400 | PASS |
| source-schema hashURL + 密码 → 200,3 列预览 | PASS |
| createSync paste 带 **hashURL**(非裸 uuid)→ 200 + 引擎拉数 3 行 | PASS |
| 裸 uuid / path 形(`…/nc/view/<uuid>`)resolve → 200(六格补齐) | PASS |

R3 lane4 M-1 症状(path 形 200 / hash 形 400)不复现;`extractSharedViewUuid` hash 段解析源码审在位(candidates 含 hash 路径段)。

## 3. R4 重点 3|响应凭据剥离 —— 过(全响应面)

- **getSync / listSyncs** 响应 `has(source_uuid)||has(source_password_hash)` 均 false
- 附加发现:createSync/updateSync/freeze/resume 均以 `return this.getSync(...)` 收尾,**剥离面自动覆盖全部写端点响应**(createSync 实测零泄露)
- 持久凭证行为面:paste resync 200 拉数成功(share 凭证仍在库生效,剥离仅响应侧,不伤引擎);mapping 明文密码不落库(P2 R1 起机制未变,bcrypt hash 直存)

## 4. R4 重点 4|漂移日志 —— 过(旧值 -> 新值 实证)

源 Note 列 SingleLineText → LongText,resync 后:

- 镜像列 uidt 跟随 = LongText(传播生效)
- 后端日志(`/private/tmp/nocodb-internal.log`,pid 96879 stdout)实测行:
  `Table sync tssyew5tc5htqbk9t: propagated column type change Note: text -> LongText`
  ——箭头左 old(`destCol.dt`)、右 new(`srcCol.uidt`),**旧≠新**,R3 M-2(new→new)不复现;processor 源码 `oldType` 在 mutation 前捕获(253c3b6ee5 diff 在位)

## 5. R4 重点 5|P1+P2 全矩阵站位

| 域 | 断言 | 结果 |
|---|---|---|
| paste 全链 | hashURL resolve→schema→create→mapping→resync 3 行 | PASS |
| selected_fields 减 | PATCH [Title,Qty] → 200,镜像 Note 列删 | PASS |
| selected_fields 增(R1 E4 回归) | 增回 Note → 新列 readonly=true → resync 后 **Note 数据 3/3 真实进数** | PASS |
| selected_fields 边界 | `[]`→400;未知字段→400 | PASS |
| 类型漂移 | 源 Note→LongText,resync 镜像跟随(bypassSyncedFieldGuard 通道) | PASS |
| resync 复检·allow_sync | 关 → resync 400;重开恢复 | PASS |
| resync 复检·browse 源权限 | api 无 SRC 角色 → createSync **404**;邀入后 createSync 200;PATCH no-access 撤权 → resync **404** | PASS |
| paste 持久凭证 | 源 base 零成员关系的 paste sync resync 正常(share 凭证语义) | PASS |
| E1 六格 | 3 输入形态(hash/path/裸 uuid)× 密码态(无/对/错)全覆盖 | PASS |
| ACL 十一端点 | editor 对 list/get/source-schema/create/update/delete/resync/freeze/resume/resolve-link/detach **全 403**;匿名 list **401** | PASS |
| 守卫链 | editor 对 synced 表 insert → **400**;owner 对 synced 表 delete(无 force)→ **400**;grid New record disabled | PASS |
| 引擎 e2e·freeze/resume | freeze 200 → paused resync 400 → resume 200 | PASS |
| 引擎 e2e·on_delete 双策略 | mark_deleted:删源 row3 → 3 行保留 + **RemoteDeleted=true ×1**;delete:切回 + 删源 row2 → resync sweep 至 1 行(row1) | PASS |
| 引擎 e2e·sweep 旁证 | SYNC2 手动 Sync now 后镜像对齐源剩余行(3→1) | PASS |
| 引擎 e2e·deleteSync | 200 → getSync 404(镜像进 trash 语义) | PASS |
| detach 转正 | 200 → getSync 404 → synced=false → readonly 列 0 → **insert 200 可编辑** → 数据保留 | PASS |
| UI·向导双模式 | Paste 模式 hashURL 全流程(step0 密码框随 URL 现 / step1 字段 / step2 删除策略 / Create 200);Browse 模式 API 侧 createSync 200 站位(R2/R3 多轮 UI 站位) | PASS |
| UI·树菜单三态 | Active:Sync 组四项 + 无 Delete table;Paused:**Resume sync 翻转**(无 reload);Syncing 竞态捕捉:**Sync 组四项全消失**(仅剩常规组,R1 M3 守卫回归) | PASS |
| UI·删除流三腿 | 腿 A Delete sync:确认弹窗(sync 名)→ confirm → 树表消失;腿 B Convert:转正后 reload **锁标消失 + New record 可用**(数据保留);腿 C 菜单翻转:**Delete table 出现 + Sync 组消失** | PASS |
| UI·editor 三入口 | 入口1 Overview 卡不可见(D3);入口2 synced 表树菜单无 Sync 组(仅 TABLE ID 面板);入口3 Share 模态简版无 Allow sync | PASS |

## 6. 质量门 —— 全绿

- `tsc --noEmit` exit 0(日志 .work/ee-ce/f09p2r4l2-tsc.log)
- jest Fork 桶:**3 suites / 41 tests 全过**(.work/ee-ce/f09p2r4l2-jest.log)
- Vite URL 编译强验(`/_nuxt/@fs/` 真实编译产物 createHotContext):CreateNewSync.vue 200/55KB、**Overview.vue 200/31KB(R3 修复文件)**、SyncMenuOptions.vue 200/30KB

## 7. 非问题观察(不计 error/minor)

1. `extractSharedViewUuid` hash 段若带 query(`#/nc/grid/<uuid>?a=b`)则 uuid 段匹配失败——官方 share URL 无 query 形态,验收口径内不复现;后续如支持带参分享链接再议
2. f01e2e xc-auth 跨 lane 秒级互踢(测试基建,§0 备忘)
3. deleteSync 的 trash 落位以 UI 树消失 + getSync 404 语义验证,未做 DB 直查(与 R3 站位口径一致)

## 证据索引

- 截图:/tmp/f09p2r4l2/shots/(creator-d2-home / wizard-step0-hashurl / wizard-step1-fields / wizard-step2-create / mirror2-grid / menu-active-state / menu-paused-state / menu-syncing-race / delete-sync-confirm / after-convert / after-convert-reload / converted-menu / editor-d3-home / editor-d1-tree-menu / editor-d1-share-modal)
- 脚本:/tmp/f09p2r4l2/(setup.sh、t1/t2/t3/t3b/t3c/t3d/t4.sh、env.sh)
- 漂移日志:grep `propagated column type change` /private/tmp/nocodb-internal.log

## 清理

- 4 个测试 base(SRC/D1/D2/D3,全 `f09p2r4l2-` 前缀)软删 200,base 列表残留 0(retry 窗口内 try 1 全成)
- lane 账号 3 个留存(f01e2e 基建模式惯例,测试口令不入仓);camoufox session f09p2r4l2 已 close;质量门日志归档 .work/ee-ce/
