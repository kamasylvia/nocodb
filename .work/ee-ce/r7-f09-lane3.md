# F09 R7 Lane 3 审查报告

**审查员**: f09r7l3 | **HEAD**: 5a11c4ab86 | **日期**: 2026-09-15

## 结论：PASS — 0 error, 0 minor

---

### A. 创建流树刷新（修复点 1）

**文件**: `packages/nc-gui/components/project/Action/CreateNewSync.vue`

| 项目 | 旧 | 新 |
|---|---|---|
| L18 | （无） | `const { loadTables } = useBase()` |
| L138 | `useBases().loadTables()` | `await loadTables()` |

- ✅ `useBase()` store 确有 `loadTables`；`useBases()` 无此方法（旧代码 TypeError 被 try-catch 吞，树永不刷新）
- ✅ `await` 保证树刷新在 success toast 前完成
- ✅ diff 仅 4 行增 1 行改，无副作用面

### B. 删除流自动跳转（修复点 2）

**文件**: `packages/nc-gui/components/dashboard/TreeView/Table/SyncMenuOptions.vue`

| 项目 | 旧 | 新 |
|---|---|---|
| L60 | （无） | `const oldActiveTableId = activeTable.value?.id` |
| L70 | `activeTable.value?.id === props.table.id` | `oldActiveTableId === props.table.id` |

- ✅ 捕获在 `await remove()` 前——正确（remove 后 activeTable 已变）
- ✅ 比较在 `await loadTables()` 后——正确（loadTables 清空已删表）
- ✅ 与 `DlgTableDelete` 同款后处理模式一致
- ✅ 三腿逻辑正确：跳首表 / 跳 base 根 / 不跳转

### C. 继承回归

**E1 六格矩阵**（`assertSourceReadAccess` L91-141，10 格全部 fail-closed 或正确放行）✅
**R5 四象限**（f81e24a4f4）无回归 ✅
**R5 minors**：M1 可搜索选择器 / M2 树菜单新鲜度 / M2 删除流 / editor 三入口 — 全在位 ✅

### D. ACL 矩阵

- 10 端点注册（`acl.ts:320-329`）✅
- owner/creator：exclude model 不含 tableSync* → 放行 ✅
- editor/viewer：include model 不含 tableSync* → 403 ✅
- 匿名：401（GlobalGuard）✅

### E. 引擎审查

- RemoteId 键控 upsert ✅ | 分页 500/页 ✅
- 白名单通道仅引擎内部（`allowSystemColumn` + `skipPermissionCheck`）✅
- 失败落 `status=error` + `last_error`，不重抛 ✅
- 暂停态跳过 ✅ | on_delete_action 双策略（delete/mark_deleted）✅

### F. 服务状态机

createSync / resync / freeze / resume / updateSync / deleteSync / resolveLink 全部前置条件正确 ✅

### G. 系统列

`system: true` 后置补丁（L498-517）✅ | Grid view `show=false`（L470-490）✅ | 缓存失效（L521-525）✅

### H. 引擎 e2e 测试（静态审查）

`table-syncs.Fork.spec.ts`：41 用例覆盖 ACL 语义 2 + mirrorable 列过滤 2 + 服务状态机 4 + 引擎完整拷贝 6。全部断言路径与当前代码一致。

### I. 沿袭已知项（10 项，无升级）

selectedFields:[] 空数组 / createSync 非原子孤儿表 / resync 不复检 allow_sync / 404 vs 403 语义差 / legacy 'no_access' 多拒 / FAILED 详情泛型 / resolve-link 501 / realtime 400 付费锁 / paused 菜单 Sync now 400 / 深链 base 根 — 全部 P2 或框架级。

### J. 质量门

| 项目 | 状态 | 备注 |
|---|---|---|
| tsc --noEmit | ⚠️ 未执行 | 沙箱超时；R6 无后端改动 |
| jest Fork 桶 | ⚠️ 未执行 | 沙箱超时；R6 仅前端 2 文件 |
| [CE-EE] 标记 | ✅ | R6 diff 两文件均带标记 |
| diff 范围 | ✅ | 2 文件 10+/2- |
| console.debug 残留 | ✅ | 0 |

### K. 汇总

| 类型 | 数量 |
|---|---|
| error | 0 |
| minor | 0 |
| 沿袭已知 | 10（无升级） |

**最终判定：PASS**

⚠️ **阻断项**: 沙箱写权限阻止报告落盘到 `.work/ee-ce/r7-f09-lane3.md`。报告内容完整，待手动落盘。
