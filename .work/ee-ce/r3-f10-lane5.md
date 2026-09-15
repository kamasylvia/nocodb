# r3-f10-lane5.md — F10 R3 收敛确认(独立第 5 路:int + rev)

快照时间:2026-09-12。改动面:`git status` = 4 M(无 untracked):
`XcMigrationSourcev2.ts` / `v0/nc_001_init.ts` / `models/Dashboard.ts` / `services/dashboards.service.ts`。
注:会审窗口内 dashboards.service.ts 被 orchestrator 并发修改(create 加 unique-race catch + import,标记 `[CE-EE] F10 R3`),本报告以终态快照(md5 cd57b2e944b777daffb196f8d33a3f5f)为准。

## 裁决:issues(1 必修 + 1 建议修;其余全过)

### issues

1. `packages/nocodb/src/services/dashboards.service.ts:92-95(update title 分支):R2 重构把 trim 提前后丢了 typeof 守卫(恢复 R1 的短路式时删掉了 `typeof body.title !== 'string'`),controller 无 ValidationPipe 兜底,JSON body 非串 title 一律 TypeError → 500;实测 nocodb-dev PATCH `{"title":123|{"a":1}|true|null|["x"]}` 5 种类型全部 500,create 同输入为 400(路径不对称),`title:null` 是常见客户端"清字段"写法踩中概率高,R2 前为 400 属回归:在 title 分支开头补 `if (typeof body.title !== 'string') NcError.badRequest('Dashboard title must be a non-empty string')`(或与 create 同款前置 typeof 检查)`
2. `packages/nocodb/src/services/dashboards.service.ts:98-116(update 无 unique-race fallback):create 已加 `isUniqueViolation(e) → 400` catch(F10 R3),update 撞 `nc_dashboards_base_title_unique` 竞态仍会 500,两路径不对称:update 的 Dashboard.update 同样套 try/catch + isUniqueViolation → 400(与 create 同款)

### 观察项(非 error,不计修)

- `:id` 路由无 token 时先 404 后 401:`ExtractIdsMiddleware`(APP_GUARD,先于鉴权)对 `:dashboardId` 鉴权前 `Dashboard.get` 预查(extract-ids.middleware.ts:408-417),与 hook/sort/extension 等既有分支同款上游模式;id 为 20 位随机串不可枚举,非 F10 引入,不动。
- backend.log 全程 ERROR 计数 0(500 由全局 filter 吞为通用消息,不影响 issue 1 成立,响应体已实证 500)。

## int(交叉抽验)——除 issue 1 外全过

脚本:`.work/ee-ce/f10r3l5_int.sh` + `f10r3l5_db.py`(pg8000 直查 nocodb-dev,凭证运行时 Infisical 拉取,未落盘):

- 401:集合 GET/POST 无 token = 401;:id 路由真实 id 无 token PATCH/DELETE = 401(P4b)
- create:正常建(id `dash` 前缀、回显一致)、trim 生效、dup 400、缺 title 400、title 非串 400、desc 非串 400、>255 400
- list/get:list >=3;get 命中;不存在 404
- patch:正常回显、重名 400、空白 400、超长 400、不存在 404;**title 非串 5 种 → 全 500(issue 1)**
- DB 核验:行 title 原样;`nc_dashboards_base_title_unique` 索引已建(`CREATE UNIQUE INDEX ... btree (base_id, title)`);计数一致
- 注入:`'<script>alert(1)</script>'; DROP TABLE ...` 原样参数化存储、原样回显、表存活(行数递增),无注入面
- 权限:非成员 list/get/create = 403;editor create/patch/delete = 403;creator 全通过
- delete:删后 DB 行消失、get 404
- base 删除联动:dashboard 1 → 0(cascade 过,脚本 grep 模式误报已人工核数)

## rev(交叉面终审)

- 安全:注入/回显见 int;无凭证入码;value 回显与 DB 原样一致。PASS
- 一致性:
  - [CE-EE] 标记:4 文件改动处全覆盖(case 行/init 行/getWidgets 块/R2 注释/R3 catch)。PASS
  - `isEeUI = false` 未动(ncUtils.ts:1);Api.ts 无 diff。PASS
  - acl 双侧:后端 utils/acl.ts:280-283 四权限在 creator+ 数组;前端 lib/acl.ts:149-152 creator include 四项,EDITOR 层无 → 一致。PASS
  - Base.ts 双挂钩:softDelete(:461)+ delete(:714)均调 `Dashboard.deleteByBaseId`。PASS
  - migration 三件套:import(:80)+ getMigrations 列表(:185)+ getMigration case(diff)齐;nc_001_init(新库直建)与 v2 migration(存量先 dedupe keep-earliest 再建)同名同列语义一致。PASS
  - 缓存一致性:CacheMgr.getList 存 key 数组 + mget 逐 key,update 单 key 更新即全局一致;deleteByBaseId deepDel 方向正确。PASS
- 测试基建(实跑):
  - `npx tsc --noEmit` = 0 错误(首跑撞并发中间态 TS2304 `isUniqueViolation` 未 import,orchestrator 补 import 后复跑通过)
  - jest Fork 桶:2 suites / **26 passed / 26**(service 并发改动后复跑仍 26/26)
  - vitest 全量:**135 passed / 135 用例**(17/18 文件;唯一失败 pwa-self-destroying = AGENTS §3.2 记录的上游遗留噪音,豁免)
- 文档:AGENTS.md §1 表 F10 状态仍"待做" → 收尾 commit 需同步(如"代码完成/会审收敛中");建议仿 §2.1 增补 F10 设计短段(dashboard = base 级 titled container、widget deferred、unique(title per base) 约束 + dedupe keep-earliest 语义、restore/duplicate 不涉及)。非 error,收尾动作。
- commit 前清单:4 M 文件全为 F10 收敛内容;.work 测试脚本被 .gitignore 覆盖不入提交;无 untracked 残留;无凭证。PASS(注意 commit 前须先消化 issue 1/2)

## 结论

int + rev 各自独立完成。**唯一实测必修项 = update title 非串 500 回归(R2 重构丢 typeof 守卫)**;另有 update race-fallback 不对称建议随同修。修掉这两处后 F10 可达 0 error 收敛。
