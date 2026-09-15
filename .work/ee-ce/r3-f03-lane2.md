# r3-f03-lane2 — F03 Data permissions R3 终局收敛轮（独立全量集成测试 + 整 diff 复审）

审查对象：7b10716231（F03 实现）+ 2f5a57b0d3 / e1e996283c / 0a3e5fdab4 / c7a242cdf3 / 6cc43e0b81（修复链）至 HEAD 6cc43e0b81。
环境：localhost:8080 dev server（未重启未杀）、qnap.elf-balance.ts.net:5432/**nocodb-dev**（硬编码，未触碰 nocodb 生产库）。
本报告为终审定稿（覆盖本文件 09:35 早稿；早稿唯一发现「bulk ADD 检查在行循环内放大 Permission.list」经查**已由修复链解决**，见 §2）。

## 结论

**PASS** — 0 个 F03 实际 error。

- OBS-1（E3，环境）:server 于 10:30 起进入外部触发的重启循环（dist/main.js 重编译 + `Restarting app...` × N、tsc --noEmit 反复触发 = 源文件被其他会话修改；进程 79767 存活但 8080 无监听 >15min，backend.log 尾部无 listening 迹象）。依纪律未干预。影响:bulk ADD 修复后的运行时 perf 复测未执行（见 §2）；核心矩阵 ~110 项已在存活窗口全部完成。
- OBS-2（E3，工具限制）:UI 交互段部分完成。已证:owner 登录、base 页 T1/T2 树项渲染正常（getAccessibleTables + 树 UI 工作）。未证:右键菜单 Table Permissions 项与弹窗交互 —— camoufox 合成 contextmenu isTrusted=false 被 NcDropdown 忽略、hover-only "..." 按钮（display:none）不在 a11y refs、mini-sidebar workspace 状态漂移。gate 逻辑经代码审确认（Node.vue:429-462 flag 化 gate + isUIAllowed('tablePermission') creator+；DlgTablePermissions v-if="table.id"）。

## 1. 全矩阵集成测试（grants × roles × ops，全 API 写 grants，独立隔离 base）

隔离环境:base `pac7273q06v7tsh`（T1=m4j83aav1hyvv7m，T2=m8jefj1z5ap0rsg），新用户 owner(super 提权)/editor/creator（psql 提权 + base 邀请），grants 全走 API。

| 矩阵 | 结果 |
|---|---|
| A 基线（0 grant）| editor/creator/owner read/insert/update/delete 全 200 — fail-open ✓ |
| B ADD nobody | editor/creator insert 403、owner 200、bulk insert 403；update/delete/read 不受拦；删 grant 后立即恢复 200 ✓ |
| C DELETE nobody | editor/creator delete 403、owner 200；v2 bulk delete 403、v1 bulk delete 403、v1 bulk deleteAll 403、owner deleteAll 200；insert 不受拦 ✓ |
| D/E/F role grants | ADD role:editor → editor 200/creator 200；ADD·DELETE role:creator → editor 403/creator 200（rolePower 生效）✓ |
| G VISIBILITY role:creator | editor data/meta/count/v1/v3 全 404（遮蔽非 403）、creator/owner 200、editor 表列表消失而 creator/owner 保留 ✓ |
| H VISIBILITY role:viewer | viewer-and-up 语义:editor/creator/owner 全 200（与 UI 档位一致）✓ |
| I VISIBILITY nobody | editor/creator 404、owner 200 ✓ |
| J VISIBILITY SPECIFIC_USERS[editor] | editor 200、creator 404、editor 列表含 T2 ✓ |
| K bulkUpsert 拆分 | 活行 update 语义不要求 ADD（N1/N2 非 403）；新 id insert 语义 403；trash 行 upsert 剥 PK 变 insert 语义 → 403 正确 ✓ |
| P v1 单条 | insert/delete 在 ADD/DELETE nobody 下 403、owner 直通 200 ✓ |

## 2. 早稿性能发现的终审核验

早稿（09:35）实测:bulk ADD 检查位于 `insert.ts` 行循环内，100 行 = 100 次 `Permission.list`（+92% 耗时）。**HEAD 已修复**:ADD 检查现位于 `for` 循环**外**（insert.ts:342-356，`if (!skipPermissionCheck)` 包裹，注释 "Row-independent — checked once here rather than per row"），import/copy/快照 skip 通道保持豁免。结构上每请求固定 2 次 `Permission.list`（extract-ids gate 1 次 + checkPermission 1 次），与行数无关。修复后的运行时 perf 对比因 OBS-1 停机未复测（E3）。

## 3. fail-open / 缓存即时性 / 校验对称

- fail-open:三 key 各验证「删 grant → 下一请求 200」（B7/N6/P5）；空清单短路（gate `permissions.length` + checkPermission `!permissions?.length`）✓
- 即时性:grant 创建/PATCH/删除后**立即**生效，全程无重启（I4-I7 nobody→viewer→nobody 往返）✓
- create 对称 12 项全 400/200:below-minimum role、table+FIELD key、field+TABLE key、不存在的表、他 base 表、user 缺 subjects、team subject、bogus type、重复 (entity,entity_id,permission)、非法 entity/permission ✓
- update 对称:below-minimum 400、bogus role 400、→nobody 清 granted_role+subjects（落库确认）、nobody→role 200、nobody+subjects 400、未知 id 404、editor 写/删 grant 403（ACL creator+）、editor list 200、enforce_for_form 往返 200 ✓

## 4. VISIBILITY 四面 + link 折叠

- meta 404 / data 404（v2+v1 id）/ count 404 / 表列表消失 / v3 404 ✓
- link 折叠:**第三列实验**——无 grant `fields=Id,Val,Extra` 返回 SECRET；VIS nobody 同请求 Extra 被剥（仅 Id+Val=pv）、`f=Extra` 返回 `{}`、owner 不折叠 ✓（注意:T2 仅 pk+pv 两列时折叠前后输出相同，须第三列才能区分）
- v1 路由 title 形式 owner 也 404 = CE 基线（:tableName 段按 id 解析），方向 fail-closed 无泄露面，非 F03 回归 ✓
- 匿名:isServiceUser(undefined)=false → 匿名进 gate → helper 回落 default visibility（有 grant=404）；语义正确。共享表单 enforce_for_form 三态沿 F02 isFormContext 机制（代码审确认，本轮未重测公开 base 提交链）

## 5. 回归

- F02:field grant 创建/可见/editor PATCH 被拦 403 ✓；F05 variables 200 ✓；F07 snapshots 200 ✓；F08 base 列表正常 ✓；F10 dashboards 200 ✓
- `tsc --noEmit` EXIT=0；jest Fork 桶 **26/26 PASS**
- 探针零残留:F03 diff 无 console/debugger/probe/TODO-F03；6cc43e0b81 已清 .v1a/.v1b/.v1c/.reasonix ✓

## 6. 代码复审（整个 F03 diff）

1. checkPermission 全收集:request-scoped 清单挂 req.context（F02 R1 语义保持）、multi-grant any-deny、owner 直通、isFormContext×enforce_for_form、TABLE label 分支 + per-key 文案（permissionDeniedMessage）✓
2. 挂点面:ADD ×5（insert single :77 / bulk :346 循环外 skip 通道包裹 / nestedInsert :3077 isFormContext / bulkUpsert 拆分后 `if (toInsert.length)` / ——）；DELETE ×3（delByPk :2250 / bulkDelete :4976 / bulkDeleteAll :5545）；link 系不挂 DELETE（对齐 EE:删行≠摘链接）✓
3. Permission.update:resolved-type 三守卫（NOBODY+subjects / ROLE 缺 role 含显式 null / USER 缺 subjects）、updateObj 对 NOBODY 删 granted_role+subjects、validateGrantShape create/update 共享 + minimumRole（SDK PermissionRolePower）✓
4. permissions.service:TABLE entity 3 key 白名单 + Model 存在/base 归属/synced 拒配 + 重复键 + team 拒 ✓
5. extract-ids:gate 前置 `ncTableId && ncBaseId && !isServiceUser`、空清单短路、404 遮蔽；v1 主路径 ncTableId 赋值（:237）+ alias 回退（:1109，c7a242cdf3）✓
6. data-table.service.ts:398 失实注释已修正 ✓
7. 前端:Node.vue gate flag 化、DlgTablePermissions 实装（Everyone=删 grant 与 helpers 注释钦定写语义对齐；VISIBILITY 选项集与 minimumRole 一致；dirty-per-key）、useExpandedFormStore 去 !isEeUI、grid/Table.vue ADD 补挂（`?? true` 冗余无害，isAllowed 恒返 bool）、Content.vue tableId prop 存在 + getPermissionSummaryLabel ✓
8. 上游预存 bug（非 F03 引入，不计 error）:v1 upsert 单行 update 批 500 —— `afterUpdate(existingRecords[0])` BaseModelSqlv2.ts:6065 ← bulkUpsert:4205，上游 2023 代码（a4e4e2f68f 同款，F03 diff 0 触碰）；ADD hook 语义经 N1/N2 与 K3 分别验证不受其影响。建议记 fork backlog。

## 结论行

PASS

（测试工件:.work/ee-ce/.lane2r3-*(suffix/env/tokens/base/t1/t2/matrix*.py)；所有 grants 已清理（终态 0 行），测试 base/用户保留可复现；mm link 行 `_nc_m2m_T1_main_T2_hidden`(15,1) 无害。）
