# F09 P2 生命周期 R3 站位回归 — lane 3(安全审计重点路)报告

**结论:PASS(0 error + 0 minor)**

基线 366e0b7045(HEAD 7db46fce29 仅多 dispatch commit,零代码变更);:8080 运行修复后 dist(pid 33253 晚于 dist mtime,特征 grep:sourceInputMode×4/resolveLink×6/bypassSyncedFieldGuard×4/updateSynced×2/detach×22/sharedViewPassword×7/source_password_hash×2)。账号 f09p2r3l3-*;camoufox session f09p2r3l3;测试资源全前缀测完已删(2 base DELETE 200 + DB 残留三表 0)。

## 1. 安全重点四项(lane 主责)

### 1.1 paste 凭据面(uuid + bcrypt hash、明文零落库零泄露)— 过
- 三入口(resolveLink/sourceSchema/createSync)密码统一 bcrypt.compare(service :477/:294/:1141),**源码无明文落库路径**:insertMainMapping 仅落 `source_uuid` + `source_password_hash`(= view.password 的 hash,:757-762)
- DB 直查(nocodb-dev,psql 经 Infisical 运行时凭证):syncB 映射行 `source_password_hash=$2a$10$...`(bcrypt 格式)、`source_uuid` 正确;`plaintext_hits=0`(like 明文串全表零命中);无密码态 syncA hash=null
- API 面:getSync 映射响应含 hash 无明文;share 视图 PATCH 响应密码 `__NC_PASSWORD_MASKED__`(上游 mask 机制)
- hash 暴露面评估:映射 API 响应含 hash 系本 fork SDK 类型自声明(`packages/nocodb-sdk/src/lib/sync/table-sync.ts:48-49`),仅 tableSyncGet(owner/creator)可达,bcrypt 不可逆——设计内,不计 issue
- View.getByUUID 全局解析(FULL_BYPASS,View.ts:1738)支撑 paste 跨 base 语义;实测无源权限账号(ui 仅 dest owner)resolve/create 全 200,凭据=链接语义成立

### 1.2 resolveLink/sourceSchema 密码三态 — 过(M1 修复回归)
| 入口 | 无密码 | 错密码 | 对密码 |
|---|---|---|---|
| resolveLink | `{passwordProtected:true}` 零泄露 | 400 | 全量坐标+pp:false |
| sourceSchema | `{passwordProtected:true}` | 400 | 全 schema |
| createSync | 400 | 400 | 200 |
R1 lane5 M1(无密码泄露标题)确认已修:resolveLink 无密码时仅返回单键。

### 1.3 detach ACL 同权边界 — 过
- controller `@Acl('tableSyncDelete')`(detach 与删 sync 同权,注释载明理由:移除 sync 才是破坏性动作)
- 实测:editor(dest editor)对 list/source-schema/resolve-link/resync/freeze/**detach** 六端点全 403;owner detach 200
- detach 后凭据销毁(DB 实证):column_mappings=0 / main_mappings=0 / sync_row=0,uuid+hash 随删

### 1.4 映射一致性 — 过(E4 回归 + DB 面)
- 列映射 DB 逐行核对:`nc_table_sync_column_mappings` src/dest title 双侧命中一致,broken_rows=0、orphan_dest_rows=0
- 增腿映射行 dest_column_id 指向 nc_columns_v2 真实列(E4 修复核心);减列后残留恰 2 行,无半态(E3 回归)
- getSync 的 `mappings` 仅含表级 main 行(不含列映射)——列映射仅 DB 可见,API 断言需走 DB(审查注记)

## 2. R1 五 error 修复回归(逐项活体)— 5/5 PASS
| # | R1 症状 | R3 实测 | 判 |
|---|---|---|---|
| E1 | paste 缺 sourceTableId 必 400 | 前端形态(不带 sourceTableId)createSync 200,full-create 3 行 | PASS |
| E2 | getColumns 用 dest context → no syncable columns | 同链数据 3 行(row1,row2,row3) | PASS |
| E3 | 减字段 500 Undefined binding + 半态 | 减 Qty → 200;列删+映射行删(DB 2 行);status active | PASS |
| E4 | 增腿 dest_column_id 落 model id 数据永不同步 | 增 Note → readonly:true + DB 映射命中真实列 → resync 后 n1,n2,n3 真实进 | PASS |
| M1 | resolveLink 无密码泄露标题 | 仅 `{passwordProtected:true}` | PASS(修复) |

## 3. P2 全矩阵 — 过
- paste 全链:resolve URL/裸 uuid 双形 + bogus 400;sourceSchema paste 预览;createSync 带密码(selectedFields 白名单)200;selected_fields 持久化
- selected_fields:增列(readonly:true+数据进)/减列/`[]`→400/`null`→200 全字段(selected_fields=null 落库)
- 类型漂移:源 Title SLT→LongText → resync → 镜像 uidt=LongText,数据 3 行完好;失败 warn 不阻塞(源码审 processor:174-178)
- detach 转正:synced=false、readonly 全解(0 列残留)、数据保留、插入 200;Syncing 中 detach 400 守卫源码审(:1178-1180,race 窗口 job 秒级不可构造)
- resync 复检:allow_sync 关 → resync 400 + resolve 400(双端点);重开 → 200 + active;browse 源权限断言源码审(:1064-1070 paste 跳过)
- 原子性:createSync 失败 → best-effort tableDelete + rethrow(源码审 :721-734,主动构造失败点不可行)

## 4. P1 抽查 — 过
realtime createSync 400(付费锁 API 面未绕过);镜像表 insert 400(synced 守卫);freeze 200 → paused 下 PATCH 400 → resume 200;无关用户 403;匿名 list/resolve 401;New record disabled(UI 只读层活体)。

## 5. UI 活体(camoufox session f09p2r3l3,账号 f09p2r3l3-ui)— 过
- 向导 paste 全链:空态「NocoDB Sync」入口 → Browse/Paste 单选 → URL + optional 密码 → Next(resolve)→ 字段步 → Create sync → 镜像表落地(synced=true,树可见)
- 树菜单(SyncMenuOptions):active 态 Sync now / Pause sync / Convert to regular table / Delete sync 四项活体;点 Convert → 菜单组即时切常规(Delete table 出现,Sync 组消失)+ API synced=false 复核
- Syncing 态守卫(M3 修复):`SyncMenuOptions.vue` :112/:162/:174 三项 `v-if status !== Syncing`(源码审);job 秒级完成活体不可抓(R1 同)
- 删除流:树菜单 Delete sync → 确认框 → 树节点消失 + API list 空 + getSync 404
- Nuxt error overlay / nuxt-error:双零
- 截图:/tmp/f09p2r3l3/shots/(wizard-step2.png / after-create.png / sync-menu-open.png / after-convert.png)

## 6. 质量门 — 全绿
- `tsc --noEmit` exit 0
- jest Fork 桶:3 suites / 41 tests 全过
- Vite URL 编译门:`/_nuxt/components/project/Action/CreateNewSync.vue` 200 + `/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` 200

## 7. 计数与注记
**0 error + 0 minor,连续 3 轮冲刺条件由各路汇总判定。**
- 历史遗留(非本轮新增):R1 M2(漂移传播当轮 destBaseModel 未重建,写入 cast 旧类型、次轮生效)R2 未列入修复范围,本轮源码复核仍在(processor:125-126 vs :153-179),实测漂移(SLT→LongText)未观察致错。维持 open minor 供 P3 权衡
- 观察项(不计):paste sync resync 未复验 source_password_hash(持久 uuid 凭据仍有效;EE 语义未定,规格未要求)
- 资产:/tmp/f09p2r3l3/(setup.sh、t1/t3/t4/t5/t6.sh、dbq.sh、dbq2.sh——DB 查询经 Infisical 运行时拉凭证,库名硬编码 nocodb-dev,凭证零落盘)
- 清理:测试 base ×2(主环境+补测环境)全删,nc_table_syncs/nc_table_sync_mappings/nc_table_sync_column_mappings 残留 0
