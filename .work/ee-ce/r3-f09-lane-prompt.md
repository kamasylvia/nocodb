你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 3 轮复审（R3）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/f09-research.md`（范围基准）与 `.work/ee-ce/f09-p1-impl-report.md`（实现自述），再按下列 8 项清单复审。

## 范围基准（P1 裁定）
- 做：Table Sync manual 档——browse 模式（非 LTAR 字段）镜像、full-create/full-resync（RemoteId 键控 upsert）、freeze/resume/delete、创建向导 + 管理面板、双入口解 gate（仅 blockTableSync）
- 不做（存在即报 error）：Custom Sync / integration 连接器、realtime/incremental、LTAR junction/shadow、paste 模式、detach 转正、字段变更传播、FEATURE_TABLE_SYNC_AUTO 解锁（须保持付费锁且 API 400 拒收 realtime）

## 复审清单（8 项）
1. **diff 审查**（71896a841f + c051bfa3db + 后续修复批，16+ 文件）：与 f09-p1-impl-report 清单一致；后端文件全带 [CE-EE] F09 标记；store/sync.ts / syncUtils.ts / acl.ts / ncUtils.ts 零改动；isSyncFeatureEnabled 恒 false
2. **引擎审查**（table-sync.processor.ts）：RemoteId 键控 upsert 正确性；分页读源（500/页）；白名单通道仅引擎内部；失败落 status=error+last_error
3. **服务审查**：assertSourceReadAccess（**R2 重写后**：要求 base 级角色，workspace 行单独不放行）；allow_sync 强制；镜像列过滤；保留名守卫；realtime API 400；system:true 后置补丁
4. **ACL 矩阵**（API 实测，非 super 账号）：owner/creator 对十端点 200（ResolveLink 501 除外）；editor/viewer 全 403；匿名 401；**无关系 workspace 用户对私有源 base 的十端点全部 403/404（R2 E1 回归重点——R1 曾 200 泄露）**
5. **引擎 e2e**（API 实测）：full-create → RemoteId 对照 → resync upsert → on_delete_action 双策略 → freeze/resume → deleteSync → trash
6. **守卫链 + 系统列**：editor 对 synced 表写全 400；RemoteId/RemoteDeleted 网格**不可见**（show=false + system=true 双保险，R2 E2 回归重点）；Fields 面板不暴露
7. **UI 段**（camoufox --session 专属）：向导三步 Back/Next/Create 按钮**在 body 渲染且可用**（R2 E1 回归重点）；管理面板全流程；editor 三入口不可见；console error 与 Nuxt overlay 双零
8. **回归 + 质量门**：F02/F03/F04/F05/F07/F08/F10 探针；AirtableImport 不回归；tsc exit 0；jest Fork 桶 41/41

## 已知限制 / 非问题（勿计 error）
resync 全字段盲刷；附件列不镜像；保留名 400；selected_fields 变更拒收（P2）；realtime 400（付费锁）；ResolveLink 501；FAILED 详情恒泛型（上游 setJobResult 零调用）；editor 直连 URL 顶栏标题（上游框架）；dev 库 700+ 测试账号；成员下拉"8 条截断"（不存在）；重复 sync 状态互踩（并发 syncing 互斥设计）

## 纪律
- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读他路报告；账号 f09r3lN-* 前缀（N=你的 lane 号），只动自己前缀
- **严禁 dev-backend*.sh / pkill / 重启后端 / psql**；8080 异常每 60s 轮询
- camoufox --session f09r3lN 专属会话（严禁 default）
- 输出压缩中文；报告落盘 `.work/ee-ce/r3-f09-laneN.md`（N=派遣附录 lane 号）

完成后最终回复：结论 + issues 摘要 + 报告路径。
