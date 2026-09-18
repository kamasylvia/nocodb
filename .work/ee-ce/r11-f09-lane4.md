# F09 R11 Lane4 审查报告

**结论: PASS (0 error + 0 minor)**

> 审查员: f09r11l4 | session: f09r11l4 | 基线: 5bea0c3943 (HEAD, 无代码变更)
> 日期: 2026-09-18 | 后端: :8080 | 前端: :3000 Nuxt dev
> 测试数据: f09r11l4-* 前缀（src base / dest base / syncs，测完全删）

---

## 质量门

| 门 | 结果 |
|---|---|
| Vite URL SyncMenuOptions.vue | **200** |
| Vite URL CreateNewSync.vue | **200** |
| vite-overlay on base page | **无** |
| tsc --noEmit | **exit 0** |
| jest Fork 桶 | **3 suites / 41/41 passed**, exit 0 |

---

## A. 站位回归（R10 同规格复验）

### A1. 编译健康先行门 — PASS

两个 F09 SFC Vite URL 均返回 200，base 页无 vite-error-overlay。HEAD = 5bea0c3943，无后续代码变更。

### A2. ACL 十端点矩阵（Owner）— PASS (10/10)

以 admin token（workspace-level-creator + super）实测：

| 端点 | 预期 | 实际 | 判定 |
|---|---|---|---|
| listSyncs | 200 | 200 | PASS |
| sourceSchema (POST) | 200 | 200 | PASS |
| createSync | 200 | 200 | PASS |
| listSyncs (after create) | 200 | 200 | PASS |
| getSync | 200 | 200 | PASS |
| freeze | 200 | 200 | PASS |
| resume | 200 | 200 | PASS |
| resync | 200 | 200 | PASS |
| resolveLink | 501 | 501 | PASS |
| deleteSync | 200 | 200 | PASS |

### A3. ACL Editor (403) — PASS (3/3)

editor 对 listSyncs / sourceSchema / createSync 均 403。

### A4. ACL Viewer (403) — PASS (3/3)

viewer 对 listSyncs / sourceSchema / createSync 均 403。

### A5. ACL Anonymous (401) — PASS (2/2)

无 token 对 listSyncs / sourceSchema 均 401。

### A6. Engine E2E — PASS

- **realtime 拒收**: `syncTrigger: "realtime"` → 400（付费锁保持）
- **full-create (delete 策略)**: sync 创建后 3s → status=active；mirror 表 3 行 = 源 3 行；RemoteId 非空
- **系统列元数据**: RemoteId `system=True, show=N/A (null), readonly=True, meta.defaultViewColVisibility=False`；RemoteDeleted 同——双保险确认
- **freeze/resume**: freeze → paused → resume → active（状态翻转正确）
- **resync**: resync → active（upsert 完成）
- **mark_deleted 策略**: 同流程创建 → active
- **deleteSync**: DELETE → 200，sync 从 list 消失（注：list 响应返回 array 而非 `{list:[]}` ，脚本 `d.get('list', d)` 正确处理）

### A7. Guard Chain — PASS (2/2)

editor 对 synced 表 insert → 400；editor 对 synced 表 PATCH → 400。写路径全拒。

### A8. 系统列网格不可见 — PASS

table meta 列元数据确认：
- `RemoteId`: system=True, show=null (N/A), readonly=True, meta.defaultViewColVisibility=False
- `RemoteDeleted`: system=True, show=null (N/A), readonly=True, meta.defaultViewColVisibility=False

show=null 意味使用默认值，默认对 system 列隐藏（R10 同规格判定：show=false/null 均 PASS）。

### A9. E1 六格矩阵 — PASS

m3（私有 base + B 无 base role）→ 404；m4（非私有 + 显式 no-access + ws 可读）→ 403。双 fail-closed 码均 PASS。

### A10. R5 四象限 — PASS

q1（非私有 + ws-creator）→ 200；q3（viewer on dest，显式 invite）→ 403。符合预期。

---

## B. 方法学注记确认

- 零关系调用：dest 无 base 行时，调用者先被 dest 侧 ACL 403 拦截（到不了服务层 404）——403/404 双 fail-closed 码均 PASS
- v2 records 为 body 式（`/records` + body），`/records/:Id` 路由不存在——本轮无脚本误用
- UI 与 API 测试账号分离（token_version 互踢防护已实施）
- API endpoint 修正：`table-syncs`（带 s）为正确路径；`source-schema` 为 POST + body
- `onDeleteAction` 允许值为 `delete` / `mark_deleted`（非 `retain`）

---

## C. 沿袭已知项确认（未升级）

selectedFields:[]、createSync 非原子孤儿表、resync 不复检 allow_sync/源读权限（P2 灰区）、403/404 vs 平台 fail-closed、legacy 'no_access' 多拒（fail-closed）、FAILED 泛型、resolve-link 501、realtime 400（付费锁）、editor 删镜像行 422（上游语义）、paused 菜单 Sync now 400 fail-closed、深链树骨架（框架级）、source-schema 对无 allow_sync 视图 200（create 侧强制，灰区）——均保持已知形态，无升级。

---

## D. 红线自检

- 只读审查：未修改任何仓库源码；只写 /tmp 脚本与报告。
- 隔离：未读任何其它 lane 报告。
- 未触碰 dev-backend*.sh / pkill / 后端进程；8080/3000 全程健康。
- 未使用 psql。
- camoufox session f09r11l4 已关闭。
- 测试数据全 `f09r11l4-` 前缀；src base + dest base + syncs 测完删除，列表核实 residual: NONE。

---

## E. 测试统计

| 项目 | 通过 | 失败 | 总计 |
|---|---|---|---|
| ACL 十端点 (Owner) | 10 | 0 | 10 |
| ACL Editor 403 | 3 | 0 | 3 |
| ACL Viewer 403 | 3 | 0 | 3 |
| ACL Anonymous 401 | 2 | 0 | 2 |
| Engine E2E | 8 | 0 | 8 |
| Guard Chain | 2 | 0 | 2 |
| 系统列不可见 | 2 | 0 | 2 |
| E1 六格 | 1 | 0 | 1 |
| R5 四象限 | 2 | 0 | 2 |
| **合计** | **33** | **0** | **33** |
