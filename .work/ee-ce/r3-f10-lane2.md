# F10 R3 会审报告 — 第 2 路（int + rev）

- 代理：lane2（独立会审子代理，隔离执行，未读他路报告）
- 日期：2026-09-12
- 环境：后端 http://127.0.0.1:8080（dev，nocodb-dev @ qnap.elf-balance.ts.net:5432 PG 18.2）
- 账号：f10r3b@ce-ee.local 登录失败（Invalid credentials）→ 按预案回落 f01e2e@ce-ee.local（org creator + super）。ACL 验证另建两个非 super 专测用户（见 int4）
- 资源前缀 f10r3b_，全部已清理（bases ×2、测试用户 ×2、/tmp 产物；终态核查 users/bases 残留均为空）

## issues

### E1. PATCH title 非串 → 500（应为 400），R2 改动引入的回归

- 文件：`packages/nocodb/src/services/dashboards.service.ts:87`
- 代码：`const trimmedTitle = (body.title as string).trim();` 在任何 `typeof` 守卫之前执行
- 复现（实测 5/5）：

| body.title | HTTP | innerError |
|---|---|---|
| `123` | 500 | `body.title.trim is not a function` |
| `null` | 500 | `Cannot read properties of null` |
| `{}` / `[]` / `true` | 500 | `body.title.trim is not a function` |

- 根因：R2 diff（`git diff packages/nocodb/src/services/dashboards.service.ts`）把 update 路径由「`typeof body.title !== 'string' || !body.title.trim()` 先判型」改为「trim 前置」，丢掉了 create 路径仍保留的 typeof 守卫（create 路径 `dashboards.service.ts:28` 有守卫，同矩阵实测全 400 通过）
- 任务判据：「title 非串 → 全 400 或明确语义」——500 既非 400 也非明确语义，判违反
- 修复建议：update 路径在 trim 前补 `typeof body.title !== 'string'` → `NcError.badRequest`（与 create 对齐）；或抽共用校验函数

### E2（观察项，非违反）. 并发竞态兜底的错误信息字段名误导

- 5 并发同 title：恰 1×200、4×400，DB 唯一索引兜底生效，行为达标
- 但 400 消息为 `base_id field unique constraint violation. Value 'pu5cnqmymoq8kqo, f10r3b_race' already exists`——约束实为 `(base_id,title)` 复合，消息只点名 base_id 且泄露内部 id。语义可辨（冲突被拒），按「禁风格意见」不计违反，仅记录

## int 实测结果（全为对 dev server 实测）

### 1. 非法输入矩阵

create（POST /api/v2/meta/bases/:baseId/dashboards）：

| 输入 | 结果 |
|---|---|
| title=123/null/{}/[]/true | 400 `Dashboard title must be a string` |
| title=""/"  "/缺省 | 400 `Dashboard title is required` |
| title 256/601 字符 | 400 `exceeds 255 characters limit` |
| title 255 字符 | 200（边界正确） |
| desc=123/{} | 400 `Dashboard description must be a string` |
| desc 600 字符 | 200（列型 TEXT 无上限，语义明确） |

patch（同资源）：空串/纯空白 400、256/601 400、desc 非串 400、desc=null 清空 200、desc 600 200、正常改名 200 —— 唯 E1 非串 500。

### 2. 跨 base

A 的 dashboardId 走 B base 路由：GET 404 / PATCH 404 / DELETE 404（`Dashboard '…' not found`）；A 路由对照 GET 200。无越权泄漏。

### 3. 并发同 title ×5

恰 1×200 + 4×400；list 端点与 DB（pg8000 直查 nc_dashboards_v2）均确认仅 1 行 `f10r3b_race`。唯一索引兜底实测生效。

### 4. ACL（非 super 专测用户）

- viewer（base 角色 viewer）：LIST/GET/CREATE/PATCH/DELETE 全 403（`Forbidden … "dashboardList/Create/Update/Delete"`）
- creator（base 角色 creator）：LIST 200 / GET 200 / CREATE 200 / PATCH 200 / DELETE 200
- 注：回落主账号带 super 角色（ACL `*` 直通），不具证明力，故另建专测用户完成验证

### 5. base 删除清理

- 删前 DB 直查：baseA 3 行 dashboard（255x / d600t / race）；DELETE base 200
- 删后 DB 直查：`nc_dashboards_v2 WHERE base_id=…` = 0 行
- 唯一索引 `nc_dashboards_base_title_unique` 在库确认（pg_indexes）
- `Base.ts` softDelete(≈:461) 与 delete(≈:714) 两条路径均挂 `Dashboard.deleteByBaseId` ✓

## rev 复审结果

1. **路由收敛**：dashboard 路由仅存于 `controllers/dashboards.controller.ts`，5 条全部 base-scoped（`/api/v2/meta/bases/:baseId/dashboards[...]`），无 dashboard-only 残留路由；noco.module.ts 注册正常。`getDashboardWithBaseCheck` 的 `baseId &&` 防御分支现为死代码但无害
2. **service 校验/查重/插入顺序**：create = 判型→trim→空→长度→desc 判型→list 查重（排除自身不适用）→insert；update = desc 判型→404 存在性→trim→空→长度→查重（`d.id !== dashboardId` 排除自身）→update。顺序正确，唯 update 判型缺失（E1）
3. **ACL 对齐**：controller 4 op `dashboardList/Create/Update/Delete` 与 `utils/acl.ts` permissionScopes.base（:280-283）逐一对应、大小写一致；viewer/commenter/editor 为 include 型不含 dashboard*（403），creator/owner 为 exclude 型默认放行（200），实测与静态分析一致
4. **迁移注册三件套**：`XcMigrationSourcev2.ts` import(:80)/list(:185)/case(:368) 齐全；迁移先去重后建唯一索引；`nc_001_init.ts:380` 同名 unique 供全新安装——v0 source（fresh）与 v2 source（存量升级）互斥执行，无重复建索引路径
5. **插入链路**：`Dashboard.insert` extractProps 不含 base_id，但 `metaInsert2`（meta.service.ts:301）从参数注入 `base_id`/`fk_workspace_id`，链路完整
6. **getWidgets**：由 `return []` 改为 `this.widgets = []; return this.widgets`，导出/导入消费方拿到同实例，无行为回归

## rev 实跑门

- `tsc --noEmit`：exit 0，零输出 ✓
- `jest baseVariableValidators`：`baseVariableValidators.Fork.spec.ts` **12/12 PASS** ✓（注：裸 `--testRegex` 会误匹配同名源码 .ts 致 1 suite failed 假阳性；默认 testRegex 下仅 Fork spec，干净通过）

## 资源清理

- base f10r3b_baseA：已删（int5 载体），dashboard 行 0
- base f10r3b_baseB：已删（200）
- 用户 f10r3b_viewer@ce-ee.local、f10r3b_creator@ce-ee.local：已删（200，终态 `users?query=f10r3b` 为空）
- /tmp 产物（token/login/conc/resp）：已清；bases 残留终态核查为空
- 注：清理中途 dev server 一度 000 不可达约 1-2 分钟（非本路操作所致，本路无重启/杀进程动作），自行恢复后补完用户删除

## 遗留

1. f10r3b@ce-ee.local 专用账号登录 Invalid credentials——建议 orchestrator 核对该账号状态（密码被改或未建）
