# r4-f08-lane3 — F08 Private Base R4 终局收敛轮（集成测试 + 代码复审）

审查对象：6aea3db097（实现）/ 2a86eb7d6c（R1）/ b1d3ec3c5b（R2）/ c8e0c83e0f（R3）。工作树 = HEAD c8e0c83e0f，git status 干净。

## 结论

**PASS**（0 error）。1 个 minor 一致性观察项（无安全影响，如实上报供裁决）。

- `packages/nocodb/src/services/views.service.ts:shareView（POST /api/v2/meta/views/:viewId/share）:private base 的 view share 创建未像 R1 的 shared-bases.service 那样拒绝，owner 可为私有 base 生成 share UUID；该 UUID 匿名访问被 R3 全拦（实测 400×3 端点类），不泄漏但产生无效链接。建议：views.service.shareView 对 base.is_private 返回 400（对齐 R1 base share 口径），或按上游 UI 预留（SharePage.vue:56 / View.vue:39 的 isPrivateBase 且 FORM 例外）仅放行 form view。`

## 逐项结果

### 1. 迁移终审 ✓
- `xc_knex_migrationsv0` 两行在位：`nc_20260913_add_is_private_to_bases` / `nc_20260913_dashboard_title_unique`（batch=2）。该 dev 库**无 v2 迁移表**（fresh install 仅跑 v0），与 R1 把迁移从 v2 搬到 v0 的决策互证。
- `nc_bases_v2.is_private`：boolean、default false、nullable YES ✓。
- `nc_dashboards_base_title_unique` 索引在 ✓。
- b1d3ec3c5b indexExists 四方言走查（pg `pg_indexes` / mysql `information_schema.statistics+DATABASE()` / sqlite `sqlite_master` / mssql `sys.indexes`）：查询语法正确；unknown dialect 回落 false（保持 pre-guard 行为）无回归 ✓。
- 附注：nc_bases_v2 上无 is_private 索引——迁移本就只加列（boolean 全扫可接受），非回归。

### 2. R3 修复验证 ✓
- **publicSharedBaseGet 三态**：
  - pub base + share link → 匿名 GET `/api/v2/public/shared-base/{uuid}/meta` = 200
  - privatize 后旧 link → 400 `"Shared base feature is not available for private bases..."`
  - 不存在 uuid → 404
  - 加测：private base 直接建 share link → 400（R1 拒绝）✓
- **palette 三态**（member，每步经 Model CRUD 触发 `cleanCommandPaletteCache` 失效缓存）：
  - 无 base_users 行 → `[]`
  - psql 新插 INHERIT 行 → 仍 `[]`（R3 过滤生效）
  - editor 行 → prv base 出现（explicit collaborator 可见）✓
  - owner 对照：pub+prv 均现 ✓
- **public 路由覆盖面**：checkViewBaseType 上游既有调用点 viewMetaGet（public-metas.service:59）+ public-datas.service ×10（:154/255/305/366/418/542/594/631/697/848）——R3 只填 placeholder 函数体即全量激活。实测私有 base 的 view meta 与 view 数据端点（v1 rows / v2 count）均 400 ✓。

### 3. 旁路抽测 8 类 ✓（member=workspace-level-editor、org-level-viewer、无 base_users 行）
| # | 路径 | 结果 |
|---|---|---|
| 1 | v2 meta baseGet | 404 ✓ |
| 2 | v2 meta baseTables | 404 ✓ |
| 3 | v2 data records / count | 404 / 404 ✓ |
| 4 | v1 meta project | 404 ✓ |
| 5 | v3 meta base | 404 ✓ |
| 6 | v2/v3 base users/members | 404 / 404 ✓ |
| 7 | snapshots / dashboards | 404 / 404 ✓ |
| 8 | export csv + PATCH/DELETE base | 404 ✓ |
| 对照 | pub base baseGet | 200 ✓ |

- **正规 API 成员增删链**：owner API 加 member（editor）→ 200 可见；API 删除 → 404 恢复。service 层缓存失效链完备。
- **方法学警示**（非产品问题）：psql 直插/直删 base_users 行会产生 NocoCache 陈旧角色（重签 token 亦不失效），导致假 200。本次以「API 路径为准 + 干净对照用户 member2（全 404）」双重复核排除。member2（无 base 行）对私有 base 全 8 类 404 ✓。
- baseList 过滤：member 列表 vs DB 全部活跃 private base（15 个）前后快照夹逼 3 轮全量比对 CLEAN ✓。

### 4. 回归 ✓
- 公开 base CRUD：baseUpdate 200、record insert 200 ✓
- 分页计数精确：pub 表 2 行，`limit=1` 翻页 `totalRows=2/isLastPage=false`、`/records/count` = 2 ✓
- F07 快照副本继承：duplicate（`pplsw4h8147skdo` "f08r4l3-prv copy"）与 snapshot（`p09ifje4578ivek` "Snapshot ... of f08r4l3-prv"，status completed）两路副本 `is_private=True` ✓（R1 duplicate.service 生效）
- F10 dashboard：owner 建 dashboard 200；member 对 pub base dashboards 403 = F10 「creator+ only」既有 acl 语义（utils/acl.ts:280），非 F08 回归；prv base dashboards 404（遮罩优先）✓
- **非 super owner 全流程**（owner2：org-level-creator + workspace-level-creator）：建私有 base ✓、self baseGet 200（baseCreate 自动插 owner 行，无自锁）、baseList 含 ✓、is_private toggle 200/200 ✓、无关用户 404 ✓、super 可见 ✓
- tsc `--noEmit` exit 0 ✓；jest 2 suites 26/26 passed ✓

### 5. 代码复审 ✓
- c8e0c83e0f diff 扫尾：palette OR 分组（非私有 OR 私有且非 INHERIT）逻辑正确；checkBaseType/checkViewBaseType 填芯后全链路 400 消息一致。
- 四 commit 累计一致性：
  - R1 的 v2 迁移残留（文件 + XcMigrationSourcev2 import/case）已全删 ✓
  - is_private 全量 gating 点一致：Base.ts（prop + insert/update extractProps）、BaseUser.ts ×2（workspace-inherited / explicit 分支）、User.getWithRoles（NO_ACCESS 短路）、extract-ids（404 遮罩 + super/伪用户/legacy api token 豁免）、duplicate.service、shared-bases.service（create/update 拒绝）、base-view.strategy、public-metas、bases-v3（members 标志用 is_private 非 default_role）、bases.service（create/update 双路严格 boolean + DOMPurify 绕过）、swagger ✓
  - Integration/sources 的 is_private 为上游**另一语义**（integration 私有性），无混淆 ✓
  - 前端：blockPrivateBases=false、store.isPrivateBase 接真实 flag、Access.vue 真实 UI、acl.ts manageBaseType（creator+）✓
  - 工作树 = HEAD，无半修残留 ✓

## E3 / 环境
- 后端 dev（localhost:8080）全程可达，未重启未杀进程。
- 测试残留：f08r4l3-* 用户 4 个、base 若干（pi9xfb3qwj1xipd pub / pp7fb54orey54k5 prv / pplsw4h8147skdo copy / p09ifje4578ivek snapshot / pksxkj5wvhqanr0 o2prv），dev 库遗留与历史轮一致，未清理。
