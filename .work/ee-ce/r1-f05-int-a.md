# r1 F05 Variables 集成测试(第 1 路:正向+边界)

实测环境:dev server http://127.0.0.1:8080(NC_DB=pg nocodb-dev),管理员 f01e2e@ce-ee.local。F05 改动 = 工作树 diff:`packages/nocodb/src/services/base-variables.service.ts`、`packages/nocodb/src/controllers/base-variables.controller.ts`(新增)+ `noco.module.ts` 注册 + 前端 acl/i18n。

## 测试结果

1. **PASS** — text 变量 CRUD 全链路 + order 自增
   - POST ×3 连建 `F05R1A_VAR_1/2/3` → HTTP 200,order=1,2,3(递增);GET list 按 order 排序;GET single 一致;PATCH value+description → 200 生效。

2. **PASS** — secret 掩码/解密/type 切换
   - POST `F05R1A_SECRET_1` (type=secret, value=`s3cr3t-p@ss`) → 200;
   - GET list:secret 行 `value` 键整个缺失(`has_value_key=False`),text 行明文 → 掩码正确;
   - GET single:解密返回明文 `s3cr3t-p@ss` → 加解密一致;
   - text→secret 切换(PATCH `{"type":"secret"}` 不带 value)后:list 仍掩码、single 解密出原明文 `val_2`;secret→text 切回后 single 返回 `val_2` 明文无损。

3. **PASS** — key 校验
   - `lower_case` → 400 `Variable key must be UPPER_SNAKE_CASE`;
   - `MY-VAR` → 400 同上;
   - `key:""` → 400 `Variable key is required`;
   - 缺 key → 400 `Variable key is required`;
   - 重名(同 base 建 `F05R1A_VAR_1`)→ 400 `already exists in this base`;
   - value 65537 字符 → 400 `Variable value exceeds 64KB limit`(create 与 PATCH 双路径均验);value 65536(边界)→ 200 通过。

4. **PASS** — key 不可改
   - PATCH `{"key":"F05R1A_NEWKEY"}` → 400 `Variable key cannot be changed. Delete and recreate`;
   - PATCH 同名 key(合法值变更随行)→ 200 放行,不误伤。

5. **PASS** — 删除后 GET 404、列表不含
   - DELETE → 200 `true`;GET → 404 `Variable not found`;立即 list → 不含该 key。

6. **PASS** — 跨 base 隔离
   - A base 的 variableId 经 B base 路由:GET / PATCH / DELETE 均 404 `Variable not found`(getVariableWithBaseCheck 校验 `variable.base_id !== baseId`)。

7. **PASS** — 权限面(代码核验,`src/middlewares/extract-ids/extract-ids.middleware.ts:1247-1289` 判定逻辑)
   - `@Acl` 默认 scope='base' → 查 `base_roles`;
   - `ProjectRoles.CREATOR`/`OWNER`(`src/utils/acl.ts:631-646`)为 exclude 式 → baseVariable* 不在 exclude 表 → 默认放行;
   - `EDITOR`/`COMMENTER`/`VIEWER` 为 include 式且无 baseVariable* → 判定 false → 403;
   - 与前端 `packages/nc-gui/lib/acl.ts`(creator include 四项,向下继承)语义一致。符合「creator/owner 放行、editor/viewer 拒绝」。
   - 附属问题见 Issues #2。

8. **PASS** — 缓存一致性(NocoCache)
   - PATCH 后立即 GET list → 返回 `val_1_updated`(新值);
   - DELETE 后立即 GET list → 不含已删项;GET 已删 id → 404。

## Issues

- `packages/nocodb/src/models/Base.ts:690`:`Base.delete` 级联只调 `Extension.deleteByBaseId`,`BaseVariable.deleteByBaseId`(models/BaseVariable.ts:338,已实现)无任何调用点 → 实测删 base A/B 后 `nc_base_variables` 残留 3 条孤儿行(测试中已手工清除)。建议:在 `Base.delete` 内 `Extension.deleteByBaseId` 处并列 `await BaseVariable.deleteByBaseId(context, baseId, ncMeta)`。
- `packages/nocodb/src/utils/acl.ts`(permissionScopes.base 列表 :135 起):`baseVariableList/Create/Update/Delete` 未注册进 permissionScopes,也未进任何 server 端角色 include(前端 acl.ts 已登记);当前功能正确仅因 CREATOR/OWNER 为 exclude 式默认放行。影响:权限枚举/角色矩阵/重复权限启动校验体系对该权限不可见。建议:server 端 permissionScopes.base 注册四名,并在 `ProjectRoles.CREATOR` include 显式登记,与前端对齐。
- `POST /api/v2/meta/bases/{baseId}/variables`(services/base-variables.service.ts:28-47):`type` 不校验枚举,实测 `{"type":"banana"}` → 200 原样入库(SDK `BaseVariableValueType` 仅 text/secret);非 secret 类型按 text 落库,低危(UI/SDK 层限定)。建议:create/update 校验 `type ∈ {text, secret}`,非法 400。
- `POST /api/v2/meta/bases/{baseId}/variables`(models/BaseVariable.ts:219-224):`body.order` 显式传入时绕过 `metaGetNextOrder` 且无唯一性约束,实测同 base 两个变量 order=1 并存,列表排序 tie 未定义。低危。建议:接受显式 order(replay/undo 场景需要)但补 order 冲突规范化,或确认上游同款行为后标注已知限制。

## 清理

base A/B/C 均 DELETE 200;孤儿 schema `pn7hnm70gp2glzx`/`ppstkyiwr40i6o2`/`pnlkq92fx4o3njg` 已 DROP(nocodb-dev);`nc_base_variables` 孤儿行已清,余量 0。

## 裁决

8/8 项 PASS。主功能(含边界校验、掩码、跨 base 隔离、缓存)全部实测通过,无阻断缺陷;4 条 issue 中 #1(base 删除孤儿行)为真实功能缺口建议必修,#2 为 ACL 注册完整性建议修,#3/#4 低危边界建议记录或顺手修。
