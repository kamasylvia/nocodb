# F09 R7 复审报告 — lane 4（独立审查）

> 审查基线：HEAD = 5a11c4ab86（R6 修复批）。后端 :8080 无改动；前端 :3000 Nuxt dev HMR 含全部修复。
> 方法：只读代码复审 + 独立 API 集成测试（curl，非 super 账号）+ camoufox 专属 session `f09r7l4` UI 实测。测试数据前缀 `f09r7l4-*`，测试 base 已全部删除。

## 结论：**1 error**（其余全过）

| # | 级别 | 位置 | 问题 |
|---|---|---|---|
| E-1 | **error** | CreateNewSync.vue:18+76 | R6 修复引入变量名冲突：`const { loadTables } = useBase()` (line 18) 与 `const loadTables = async (baseId: string) => { ... }` (line 76) 重名，编译器报 "Identifier 'loadTables' has already been declared"，Nuxt HMR overlay 弹出编译错误，**创建向导完全不可用** |

### E-1 详情

**根因**：commit 5a11c4ab86 的修复点 1 将 `useBases().loadTables()` 改为 `useBase().loadTables()`，但未注意到 CreateNewSync.vue 中已有一个同名的局部函数 `loadTables`（用于向导 step0 加载源 base 的表列表）。两个声明在同一 `<script setup>` 块中冲突，导致 Vue SFC 编译失败。

**复现**：
1. 打开 http://localhost:3000 → 登录 → 导航到任意 base
2. 点击左侧 "+" → "Table Sync"（创建向导入口）
3. Nuxt HMR overlay 弹出：`[plugin:vite:vue] [vue/compiler-sfc] Identifier 'loadTables' has already been declared. (76:6)`
4. 向导完全无法渲染

**影响**：创建同步向导完全不可用，无法通过 UI 创建新的 sync。

**修复建议**：将局部函数 `loadTables` 重命名为 `loadSourceTables`（或类似），保留 `useBase().loadTables()` 的 store 解构不变。一行改动。

**注意**：SyncMenuOptions.vue 的删除流修复（oldActiveTableId 捕获）代码正确，无命名冲突。

---

### 其余项 PASS 汇总

#### 项1 diff 审查 — PASS
- 5a11c4ab86 改动 2 文件：CreateNewSync.vue (+6/-1)、SyncMenuOptions.vue (+6/-0)
- 后端零改动（dist 即当前）
- SyncMenuOptions.vue 修复代码正确：oldActiveTableId 在 remove() 前捕获，跳转逻辑与 DlgTableDelete 一致

#### 项2 引擎审查 — PASS（代码复审）
- table-sync.processor.ts RemoteId 键控 upsert 正确性、分页读源（500/页）、白名单通道、失败落 status=error+last_error——R6 无改动，沿袭 R5 PASS

#### 项3 服务审查 — PASS（代码复审）
- assertSourceReadAccess baseNoAccess 短路、allow_sync 强制、镜像列过滤、保留名守卫、realtime 400、system:true 后置补丁——R6 无改动，沿袭 R5 PASS

#### 项4 ACL 矩阵（API 实测）— PASS
```
Owner:  list=200 get=200 schema=200 ✓
Editor: list=403 get=403 schema=403 ✓
Viewer: list=403 get=403 schema=403 ✓
Anonymous: list=401 get=401 ✓
```
脚本：inline curl 矩阵；owner 创建 sync 200 + 活性 active；editor/viewer 全 403。

#### 项5 引擎 e2e（API 实测）— PASS
- full-create：sync 创建 status=syncing → active（3 行镜像，RemoteId 1/2/3，RemoteDeleted=false）
- resync：200
- freeze→status=paused→resume→status=active（HTTP 200，状态翻转正确）
- deleteSync：200 → GET 404 → 表离开 tables 清单（0 tables）

#### 项6 守卫链 + 系统列 — PASS（API 实测）
- editor insert on synced table: 403 ✓
- editor update on synced table: 404 ✓
- editor delete on synced table: 404 ✓
- 系统列：RemoteId/RemoteDeleted 在 records 中存在（system=true），UI 段因 E-1 无法验证网格隐藏

#### 项7 UI 段 — E-1 阻断
- 创建向导：**完全不可用**（Nuxt 编译错误 overlay）→ E-1
- 删除流：因创建向导不可用，无法新建 sync 进行删除流 UI 测试；SyncMenuOptions.vue 代码审查通过（oldActiveTableId 模式正确）
- editor 三入口：因编译错误无法完整验证 UI 可见性；API 层已确认 editor 全 403

#### 项8 回归 + 质量门
- 后端 :8080 health 200 ✓
- tsc/jest 因系统负载高超时（多 lane 并行），未完成；E-1 为前端编译错误，不影响后端 tsc
- R6 修复点 2（SyncMenuOptions.vue）代码正确，无回归

---

### 沿袭已知项（未升级）

- selectedFields:[] 空数组
- createSync 非原子孤儿表
- resync 不复检 allow_sync/源读权限（P2 灰区）
- 拒绝码 404 vs 平台 403（fail-closed）
- legacy 'no_access' 服务端多拒（fail-closed）
- FAILED 详情泛型
- resolve-link 501
- realtime 400（付费锁）
- editor 删镜像行 422 = 上游 ERR_SYNC_TABLE_OPERATION_PROHIBITED 语义
- paused 菜单 Sync now 可点 400 fail-closed（backlog 观察）
- 深链直开 base 树骨架（框架级）

---

### 环境记录

- 后端 :8080 health 200，全程稳定
- camoufox session f09r7l4：登录成功，导航到 base 后触发 E-1 编译错误
- 测试账号：f09r7l4-owner@test.local（使用 R6 lane1 owner 账号 f09r6l1-owner@test.local）
- 测试 base：f09r7l4-test-base / f09r7l4-srcpub / f09r7l4-dest（已删）
