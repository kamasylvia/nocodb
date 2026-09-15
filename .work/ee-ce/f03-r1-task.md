# F03 Data permissions 复审任务书（R1，外部阵容）

> 输出风格：压缩模式——去冠词/填充词/客套，保留全部技术实质；格式 [事实][动作][原因].[下一步]；错误原文引用。

## 你的任务
独立执行 F03（Data permissions：表级 TABLE_RECORD_ADD / TABLE_RECORD_DELETE / TABLE_VISIBILITY 三 grant key）的**功能全量集成测试 + 代码复审**，报告落盘。

## 隔离纪律（违反即作废）
- 只读：仓根 AGENTS.md、.work/ee-ce/TASK.md、源码、git diff、.work/ee-ce/f03-research.md、.work/ee-ce/f02-research.md
- 禁读：其他 lane 报告（r1-f03-lane*）与任何 r*/patrol-* 归档
- 与其他 4 路完全同规格、互隔离、各自结论

## 审查对象（commit 范围）
- 4b26d7a23f F02 实现（基础设施，已过八轮审查——重点看 F03 对它的复用是否引入回归）
- 7b10716231 **F03 实现（主审对象）**：TABLE_RECORD_ADD 4 钩（insert.ts single+bulk/nestedInsert/bulkUpsert 拆分后）、TABLE_RECORD_DELETE 3 钩（delByPk/bulkDelete/bulkDeleteAll）、TABLE_VISIBILITY extract-ids 中间件遮蔽、permissions.service 解封 table entity、DlgTablePermissions 弹窗、Node.vue/Content.vue/expandedFormStore gate

## 语义基线
- fail-open：无 grant = allow；owner 直通；multi-grant any-deny（任一拒绝即 403）
- TABLE_RECORD_ADD minimumRole=editor；DELETE=editor；VISIBILITY=viewer（viewer/commenter grant 400）
- VISIBILITY「Everyone」= 删 grant 行；nobody = 除 owner 全拒
- enforce_for_form 默认 true：匿名表单提交受限表 ADD 时 403；=false 放行
- skipPermissionCheck：import/copy/快照通道免检（TABLE_RECORD_ADD 不得误拦）
- 内部清理（trash 永久删、F07 快照 meta 删）不走公有 delete 方法，无需豁免

## 集成测试范围（dev server :8080 已运行；行为异常等 2min 重试）
- 认证：POST /api/v2/auth/user/signup {email,password:"Xx#12345"} → POST /api/v2/auth/user/signin 取 token；v1 meta 用 xc-auth 头；owner 号 psql 提权 roles='super'（signin 前）；editor 先 signup 再邀请（POST /api/v1/db/meta/projects/:baseId/users roles=editor）
- v2 数据：插入 POST /api/v2/tables/:tid/records 平铺对象；更新 PATCH /records（body 含 Id）；v1 插入 POST /api/v1/db/data/noco/:baseId/:tableId
- 测试矩阵：nobody/role(editor)/role(creator) grants × editor/creator/owner × insert/delete/update/bulk/visibility；fail-open 往返；enforce_for_form 双态；skip 通道（快照/duplicate 不误拦）；交叉重名列 title↔column_name 劫持回归
- DB：qnap.elf-balance.ts.net:5432 库名**硬编码 nocodb-dev**（Infisical DB_NAME 值为生产库名 nocodb，**严禁引用**）。psql=/opt/homebrew/opt/libpq@18/bin/psql。凭证 Infisical KDL：set -a; . ~/.zcode/.env; set +a;TOKEN=$(infisical login --method universal-auth --client-id "$INFISICAL_CLIENT_ID" --client-secret "$INFISICAL_CLIENT_SECRET" --domain "$INFISICAL_URL" --plain 2>/dev/null);infisical secrets --token "$TOKEN" --projectId "$INFISICAL_PROJECT_ID_KDL" --env dev --recursive --plain --domain "$INFISICAL_URL/api"。权限行测试走 API 或插新行（UPDATE 有 NocoCache 伪影）
- 回归：F05 变量/F07 快照/F08 私有 base/F10 dashboard/F02 字段权限抽测；tsc 0；jest 26/26（cd packages/nocodb && npx jest / npx tsc --noEmit）

## 代码复审
git show 7b10716231 全 diff + 4b26d7a23f 基础设施调用链。重点：三键匹配 Set 全收集误拦面；update() 三守卫；extract-ids VISIBILITY 404 遮蔽（匿名/owner/service user 三态）；校验错误消息不泄漏；skip 通道完整。

## 报告（落盘 .work/ee-ce/r1-f03-lane{N}.md + 最终消息摘要）
结论行 PASS 或 issues 列表（`文件:位置:问题:建议`）+ 逐项断言 + 证据（请求/响应/psql 核值）。禁风格意见。外部限制有诊断证据记 E3 不算 error。测试数据清理（删 base/权限行）。
