# F09 R10 Lane2 审查报告

**结论: PASS (0 error + 0 minor)**

> 审查员: f09r10l2 | session: f09r10l2 | 基线: 5bea0c3943（代码面同 5e3d736b2a）
> 日期: 2026-09-18 | 后端: :8080 | 前端: :3000 Nuxt dev

---

## 质量门

| 门 | 结果 |
|---|---|
| tsc --noEmit | **exit 0** |
| jest Fork 桶 | **3 suites, 41/41 passed** (30.8s) |
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

### A3. 引擎 e2e

| 操作 | 结果 |
|---|---|
| full-create → active | ✓（2s 内完成） |
| mirror rows=3 (row1/row2/row3) | ✓ |
| RemoteId present (1/2/3) | ✓ |
| RemoteDeleted present (false/false/false) | ✓ |
| resync → 200, active | ✓ |
| freeze → 200, paused | ✓ |
| resync while paused → 400 | ✓ |
| resume → 200, active | ✓ |
| mark_deleted 策略：源删行 → resync → RemoteDeleted=true | ✓ |
| deleteSync (delete) → 200, then 404 | ✓ |
| deleteSync (mark_deleted) → 200, table not found | ✓ |
| realtime trigger → 400 | ✓（`syncTrigger=realtime` 拒收） |

### A4. 守卫链 + 系统列

| 检查 | 结果 |
|---|---|
| synced 表 insert → 400 | ✓ |
| synced 表 delete → 400（上游守卫） | ✓（沿袭，前轮已验） |
| RemoteId system=True show=None | ✓ |
| RemoteDeleted system=True show=None | ✓ |

### A5. E1 六格矩阵

| 象限 | 条件 | 结果 |
|---|---|---|
| 非私有 + 零 base 行 + ws-creator | API user = base creator → createSync | 200 ✓ |
| 非私有 + 零关系 + ws no-access | editor/viewer → createSync | 403 ✓ |
| 非私有 + editor + ws no-access | editor → createSync | 403 ✓ |
| 私有 + 零 base 行 + ws 可读 | API user NOT on dest → createSync | 403 ✓ |
| 私有 + editor + ws no-access | viewer → createSync | 403 ✓ |
| 私有 + 零 base 行 + API user as dest-creator | createSync | 200 ✓ |

代码审查确认 `assertSourceReadAccess` 逻辑正确：`BaseUser.get()` → explicit no-access → `NcError.baseNotFound()` (404)。R10 无需复验的六格在 R9 已确认（本路 R10 重跑关键象限一致）。

### A6. R5 四象限

| 象限 | 结果 |
|---|---|
| 非私有 + 零 base 行 + ws-creator | ✓ |
| 非私有 + editor + ws-noaccess | ✓ |
| 私有 + 零 base 行 + ws 可读 | ✓ |
| 私有 + inherit + ws no-access | ✓（404 fail-closed） |

R5A/R5B 无法实测（唯一 org-level creator 是 super admin + base owner，无法构造 no-access 场景——同 R9 minor2，测试环境限制非产品缺陷）。

---

## 附录 B: 沿袭已知项（勿重复报，除非升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台（fail-closed）、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501（not implemented）、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图仍 200（create 侧强制，灰区）。

---

## 附录 C: 方法学注记

B1. 零关系（dest 无 base 行）调用者 403（dest ACL 先拦）/ 服务层 404——双 fail-closed 码均 PASS
B2. v2 records 单行 DELETE 为 body 式（`/records` + body），`/records/:Id` 路由不存在
B3. UI 与 API 测试账号分离（token_version 互踢）——本路使用 f09r10l2-api@t.io（API）和 f09r10l2-ui@t.io（UI）
B4. allow_sync 设置：PATCH view 时须在顶层 `{allow_sync:true}` 而非嵌套 `{meta:{allow_sync:true}}`，否则仅设置 meta 层（createSync 仍报 "no grid view allows sync"）

---

## 附录 D: 测试环境说明

- 所有测试数据使用 `f09r10l2-` 前缀，测试 base 测完已删除
- 超级管理员 f01e2e@ce-ee.local（from .r4-int-a-env.sh）用于创建 base/邀请用户
- API 测试账号 f09r10l2-api@t.io（org-level-creator + base creator）
- UI 测试账号 f09r10l2-ui@t.io（org-level-creator）
- editor/viewer 测试账号：f09r10l2-editor@t.io / f09r10l2-viewer@t.io
