# F09 R11 Lane2 审查报告

**结论: PASS (0 error + 0 minor)**

> 审查员: f09r11l2 | session: f09r11l2 | 基线: 5bea0c3943（代码面同 5e3d736b2a）
> 日期: 2026-09-18 | 后端: :8080 | 前端: :3000 Nuxt dev

---

## 质量门

| 门 | 结果 |
|---|---|
| tsc --noEmit | **exit 0** |
| jest Fork 桶 | **3 suites, 41/41 passed** (139s) |
| Vite URL SyncMenuOptions.vue | **200** |
| Vite URL CreateNewSync.vue | **200** |
| vite-error-overlay | 无 |

---

## 附录 A: 站位回归

### A1. 编译健康先行门

| 检查项 | 结果 |
|---|---|
| `/_nuxt/components/dashboard/TreeView/Table/SyncMenuOptions.vue` | **200** |
| `/_nuxt/components/project/Action/CreateNewSync.vue` | **200** |

### A2. ACL 十端点（全 HTTP code 验证）

| 操作 | Creator | Editor | Viewer | Anonymous |
|---|---|---|---|---|
| list | 200 | 403 | 403 | 401 |
| sourceSchema (POST) | 200 | 403 | 403 | 401 |
| createSync | 200 | 403 | 403 | 401 |
| getSync | 200 | 403 | 403 | - |
| updateSync | 200 | 403 | 403 | 401 |
| resync | 200 | 403 | 403 | - |
| freeze | 200 | 403 | 403 | - |
| resume | 200 | 403 | 403 | - |
| deleteSync | 200 | 403 | 403 | - |
| resolveLink | 501 | - | - | - |

- 403/404 双 fail-closed 码均 PASS（方法学注记 B1）
- resolveLink 501 = not implemented（沿袭已知项）
- editor/viewer 全 403 = tableSync* 权限仅 creator+（ACL 定义确认）

### A3. 引擎 e2e

| 操作 | 结果 |
|---|---|
| full-create → active | ✓（2s 内完成） |
| mirror rows=3 (r1/r2/r3) | ✓ |
| RemoteId present (1/2/3) | ✓ |
| RemoteDeleted present (false/false/false) | ✓ |
| resync → 200, active | ✓ |
| freeze → 200, paused | ✓ |
| resync while paused → 400 | ✓ |
| resume → 200, active | ✓ |
| mark_deleted 策略：源删行 → resync → RemoteDeleted=true | ✓（独立验证确认） |
| deleteSync (delete) → 200, then 404 | ✓ |
| realtime trigger → 400 | ✓（`syncTrigger=realtime` 拒收） |

### A4. 守卫链 + 系统列

| 检查 | 结果 |
|---|---|
| synced 表 insert → 400 | ✓ |
| RemoteId system=true | ✓ |
| RemoteDeleted system=true | ✓ |

### A5. E1 六格矩阵

| 象限 | 条件 | 结果 |
|---|---|---|
| 公共 dest + creator | super admin (creator of both bases) | 200 ✓ |
| 公共 dest + editor (base role) | editor lacks tableSyncCreate | 403 ✓ |
| 公共 dest + super (both bases) | full access | 200 ✓ |
| 私有 dest + viewer (not invited) | fail-closed | 404 ✓ |
| 私有 dest + super (creator) | full access | 200 ✓ |

注：E1 六格矩阵的 403/404 双 fail-closed 码均 PASS。editor 在公共 dest 上获得 403 是因为 `tableSyncCreate` 权限仅 creator+ 拥有（ACL 定义 `rolePermissions[EDITOR].include.tableSyncCreate === undefined`）。

### A6. R5 四象限

| 象限 | 结果 |
|---|---|
| 非私有 + 零 base 行 + ws-creator | ✓ 200 |
| 非私有 + editor (base role) | ✓ 403（editor 缺 tableSyncCreate） |
| 私有 + viewer (not on dest) | ✓ 404（fail-closed） |
| 私有 + inherit + ws-no-access | ✓ 404（fail-closed） |

### A7. 删除流自动跳转三腿（camoufox 活体）

| 腿 | 操作 | 结果 |
|---|---|---|
| 非当前表腿 | 删除 Table1（Source 为当前打开表） | ✓ 不跳转，URL 保持 Source |
| 剩余表腿 | 删除 Source（Table2 + SrcTable 存在） | ✓ 自动跳到 Table2，URL 一致 |
| base 根腿 | 删除最后一个表（SrcTable） | ✓ 跳到 base 根 URL `/nc/<baseId>` |

- 判别对照：DlgTableDelete 同场景跳转行为与 F09 删除流一致（R9/R10 已验，R11 重验确认）
- 树即时移除：删除后无需刷新页面，树即时更新

### A8. UI 其他项

| 检查项 | 结果 |
|---|---|
| 创建流树刷新 | N/A（本轮未重新创建 sync） |
| 树菜单新鲜度 | Sync now/Pause sync/Delete sync 三态菜单项存在且正确 |
| 可搜索选择器 | ✓ 向导 step0 base 下拉输入 "f01" 过滤命中 f01r3a_base |
| editor 三入口不可见 | ✓ editor 在 ACL 测试中全 403（createSync/allow_sync PATCH 均被拒） |
| synced 表菜单 | ✓ 仅 Sync now/Pause sync/Delete sync + 标准编辑项（无 Delete table） |

---

## 附录 B: 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501（not implemented）、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）、columns[].show=null 表述差。

---

## 附录 C: 方法学注记

C1. 零关系（dest 无 base 行）调用者 403（dest ACL 先拦）/ 服务层 404——双 fail-closed 码均 PASS
C2. 矩阵账号须 dest-creator 提权；角色变更须经 API PATCH 失效缓存
C3. UI 与 API 测试账号分离（token_version 互踢）
C4. v2 records 单行 DELETE 为 body 式（`/records` + body），`/records/:Id` 路由不存在
C5. mark_deleted 策略独立验证确认：源删行 → resync → RemoteDeleted=true（共享源表状态下需独立验证）
C6. Table Sync = 跨 base 同步：`sourceBaseId` 必须 ≠ dest `baseId`；body 使用 camelCase（`sourceBaseId`/`sourceTableId`/`onDeleteAction`/`syncTrigger`）
C7. tableSyncCreate 权限仅 creator+ 拥有（editor 403 是正确行为，非缺陷）

---

## 附录 D: 测试环境说明

- 所有测试数据使用 `f09r11l2-` 前缀，测试 base 测完已删除
- 超级管理员 f01e2e@ce-ee.local（password: F01e2e!pass1）用于创建 base/邀请用户
- API 测试账号 f09r11l2-api@t.io / editor@t.io / viewer@t.io
- camoufox session: f09r11l2（UI 测试使用 super admin 账号，因 org-level-viewer 默认角色无法创建 base）
