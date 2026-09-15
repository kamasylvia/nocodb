# r1-f08-lane4 — F08 Private Base 浏览器 UI 实测 + 代码复审（R1）

审查对象：commit 6aea3db097（feat: add Private Base F08）
审查方式：camoufox UI 实测（camoufox-cli 回退）为主 + diff/源码复审为辅
日期：2026-09-13

## 结论：issues 列表（2 error + 1 finding + 1 观察）

- `packages/nocodb/src/meta/migrations/XcMigrationSourcev2.ts:186(F08 注册处): F08 迁移只注册进 XcMigrationSourcev2,而应用 boot 只无条件运行 XcMigrationSourcev0(src/meta/meta.service.ts:1151-1155;v2 source 仅在 legacy xc_knex_migrations 表有记录时才跑,meta.service.ts:1127-1141): is_private 列从未被创建,BaseUser.getProjectsList 新增的 raw 子查询引用 nc_bases_v2.is_private → GET /api/v1/db/meta/projects/ 对全员返回 42703「The column does not exist」,base 列表 API 全局故障。建议:将 nc_20260913_add_is_private_to_bases 按 v0 source 前例(F05 的 nc_202604290000_base_variables_and_sandbox_changelog)注册进 XcMigrationSourcev0 的 import + migrations 数组 + getMigration case。附:同 commit 型隐患,F10 的 nc_20260913_dashboard_title_unique 也只注册在 v2 source(grep v0 source 0 命中),因缺索引不触发 42703 故 F10 未爆雷,提请 F10 lane 复核。`
- `packages/nocodb/src/services/bases.service.ts:131: is_private 被放进 extractPropsAndSanitize 白名单,该函数(src/helpers/extractProps.ts:12)对每个字段执行 DOMPurify.sanitize(value),而 DOMPurify 对 falsy 入参返回 ""(实测 DOMPurify.sanitize(false)==="" ,sanitize(true)==="true"): PATCH {"is_private":false} 落库值变 '' → PG 22P02「Invalid data type or value for column 'is_private'」→ 400,私有化后永远无法经 API 解除私有(实测:true→200,false→连续 2 次 400;直接 SQL 对同列双向 UPDATE 均成功,排除 DB 层)。建议:is_private 移出 extractPropsAndSanitize 白名单,改用普通 extractProps(nocodb-sdk 版保留类型)单独提取该字段,或对 boolean 跳过 sanitize。`

- finding（UI 缺口,非 error）: UI 无 is_private 开关,私有状态唯一管理途径是 API。实测 base settings 仅「Invite Members to Base」「MCP Server」两个 tab(截图 /tmp/f08-l4-settings-general.png);nc-gui 全源码 grep 无任何写 is_private 的组件入口(仅 packages/nc-gui/utils/baseCreateUtils.ts:22 的类型定义)。另:EE 私有语义的前端接线(store/base.ts:80 `isPrivateBase = computed(()=>false)` CE stub,驱动 View.vue:407 顶栏 Private 锁 badge、AccessSettings.vue:642 私有提示条、ShareBase/SharePage 分享限制)本 commit 未触碰——owner 进入私有 base 时顶栏不显示 Private badge,属后续 UI 接线范围,建议记入功能 TODO。
- 观察（非 error,记录实际表现）: 无协作者用户浏览器直链私有 base 表页 URL(/ws/baseId/tableId)→ 页面呈永久 skeleton 空壳(侧栏骨架屏+空主区),无 404 页、无错误提示,但零数据/base 名泄露(ui-f08-l4-member.png 第 1 张)。前端对 404 base 的 UX 呈现是骨架卡死,可接受但不友好。

## 测试环境披露（合规性）

- camoufox MCP 拒绝 localhost 目标(`Blocked private network target: localhost`)→ 按预案回退本机 camoufox-cli 0.7.3,非 E3。
- 运行中后端(pid 24645,08:19 启动)经 rspack watch 已载入 F08 代码(dist/main.js 08:18 含 add_is_private_to_bases+bu2 子查询),但 boot 迁移未建列(见 error 1)——**这正是 error 1 的实测现场**。为解锁测试,对 nocodb-dev 手工执行等价迁移 up(`ALTER TABLE nc_bases_v2 ADD COLUMN is_private boolean DEFAULT false`,只读红线未破;未写迁移记录行),并为本 lane 3 个测试号提升 workspace 角色(signup 默认 workspace-level-no-access 无法 baseCreate)。测试数据:base「F08UI-26198」(pakbrrszsndvcag,Table1=m3aegofmsj7c182),账号 f08r1l4.{owner,member,outsider}@26198.test.local;收尾已将 is_private 还原 false(DB 直改,因 API 缺陷)。
- 任务书 setup(邀请 member 后再置私有)与步骤 b(member 不可见)自相矛盾:私有后显式协作者本就可见。按 commit 语义增补第三角色 outsider(工作区 editor、无 base_users 行)承担「不可见」断言,member 承担「协作者可见」断言。

## UI 步骤逐项结果

| # | 步骤 | 结果 |
|---|---|---|
| a | owner 登录 → base 列表 | 列表含「F08UI-26198」(Owned by me 分组);点击进 base,Table1 grid 正常渲染;顶栏无 Private badge(stub 预期) → 截图 `.work/ee-ce/ui-f08-l4-owner.png` |
| b | outsider 登录 → 列表 | 40 bases,DOM innerText 断言不含「F08UI-26198」;直链私有 base 表页 URL → 永久 skeleton 空壳,零泄露 → 截图 `.work/ee-ce/ui-f08-l4-member.png` |
| c | API 加 outsider 为协作者 → UI reload | base 卡片出现,可进入 grid 渲染正常(URL /w9qi3ljd/pakbrrszsndvcag/.../table1-table1) |
| d | is_private 切换 | API 层:true→200 / false→400(error 2);UI 协作者可见性由 c 覆盖 |
| 3 | 设置页开关走查 | 无 is_private 开关(见 finding);截图 /tmp/f08-l4-settings-general.png |
| 4 | console/网络 | 私有 base 表页装 error+fetch 监听后 ZERO_JS_ERRORS_5XX;全程无 5xx;无新增 JS error |

## API 佐证（辅,均 nocodb-dev 实测）

- outsider(工作区继承,无 base_users 行): 列表不含(0) / baseGet 404 / tables 404 / records 404 —— 存在性隐藏符合设计
- collaborator(member,editor 行): 列表含 / baseGet 200 / records 200
- owner: 列表含 / baseGet 200
- is_private:false PATCH 400(见 error 2);true PATCH 后 outsider 列表 0(正确)

## 覆盖统计

- UI 实测: 登录/列表/进 base/直链/协作者复现/设置页走查 = 6 场景;截图 2 张归档 + 1 张 /tmp
- 代码复审: commit 全量 diff(7 文件)逐文件读;nc-gui 影响面(grep is_private/isPrivate 全命中点 15 处逐一判定);迁移注册机制(meta.service.ts init + v0/v2 source 对照)
- error 2 项;finding 1 项;观察 1 项
