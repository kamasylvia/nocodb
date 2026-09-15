# r7-f05-int-a.md — F05 Variables 第 7 轮集成测试(正向+边界)

账号 f05r7a@ce-ee.local(org-viewer,baseCreate 403 按预案回落 f01e2e@ce-ee.local 建 base);base p0azqsyzvkfkytc(主)/ phzzank2n4mwwqh(隔离对照),测后已删。全部为 127.0.0.1:8080 实测。

## PASS(0 error)

### T1 create/update 四轴校验 — PASS
- create 非法全 400(实测):type="numeric"(C-01)/ type=123(C-02)/ type={} (C-03)/ value=123(C-04)/ value={} (C-05)/ value 65537 chars(C-06)/ description={} (C-07)/ description=[](C-08)/ key 缺失(C-09)/ key=""(C-10)/ key=123(C-11)/ key 256 chars(C-12)。
- create key 格式非法 400(模型层 KEY_REGEX `/^[A-Z][A-Z0-9_]*$/`,BaseVariable.ts:18):小写 key(C-16)、数字开头 key(C-17)。
- create 边界合法 200:key 255 chars + value 65536 chars + description=null(C-13,回读 key_len=255/value_len=65536/desc=None)、type 显式 "text"(C-14)、description 缺省(C-15)。
- update 非法全 400(实测):type 非法(U-01)/ value={} (U-02)/ value 65537(U-03)/ description={} (U-04)/ key 变更(U-05)/ 空 body {} → "Nothing to update"(U-06)/ value=123(U-07)。
- update 边界合法 200:key 传相同值 + description 改(U-08)、value=null 清空 → 回读 value=''(U-09)、description=null 清空 → 回读 null(U-10)、value 65536(U-11)、type 同值 PATCH(U-12)。

### T2 text/secret CRUD 全链路 — PASS
- text:create 200(T2-CR1)→ GET 回读 value/type/key 全一致(T2-CR2)→ update 200(T2-CR3)→ delete 200(T2-CR4)→ 删后 GET 404(T2-CR5)。
- secret:create 200(T2-SC1);GET×3 回读 value 恒为 "s3cr3t-value!"(T2-SC2-get1/2/3,解密稳定,无 NC_CONNECTION_ENCRYPT_KEY 静默明文问题);list 双掩码:secret 行 value 与 default_value 字段均不存在于响应(T2-SC3),text 行 value 正常返回(T2-SC3b)。
- type 双向切换:text→secret 200(T2-SW1)切后 GET value="v"/type=secret(T2-SW2);secret→text 200(T2-SW3)切后 GET value="v"/type=text(T2-SW4);secret 行 value 轮转 update 200 + 回读 "rotated-secret!"(T2-SW5/SW6);secret 无 value 创建 200(T2-SC4,回读 value=None)。

### T3 key 不可改 / 404 面 / 跨 base 隔离 / 并发 — PASS
- key 不可改:PATCH key="HACKED_KEY" → 400,且回读 key 仍为原值 C14_KEY(T3-K1)。
- 404 三类:① 不存在 variableId GET → 404(T3-N1);② baseId 与 variable 属 base 不匹配(跨 base URL)GET → 404(T3-N2,同 var 经自身 base URL 200 sanity);③ PATCH/DELETE 不存在 variableId → 404(T3-N3×2)。不存在 base 的 variables list → 404。
- 跨 base 隔离:base B 创建同 key T2_SECRET_VAR 200(T3-X1);base B list 仅 1 行自身变量(T3-X2),base A list 5 行互不可见。
- 并发同 key:5 并发 POST → 恰 1×200 + 4×400(T3-R1,两轮复测同结果);落库该 key 恰 1 行(T3-R2)。竞态走 DB unique 约束回落 400,无 500。

### T4 删 base 零残留 — PASS
- 方法:owner 经 API DELETE 两 base(各 200)→ uv pg8000 连 qnap.elf-balance.ts.net:5432/nocodb-dev(先 `SELECT current_database()` 断言 = nocodb-dev,未触碰生产库;凭证 Infisical KDL DB_*,进程内不落盘)。
- 删前:nc_base_variables base A=7 行、base B=1 行;删后:**nc_base_variables = 0 行,物理清除,零残留**。
- F05 清理链实证:工作区 diff Base.ts 在软删与硬删两路径均挂 `BaseVariable.deleteByBaseId`([CE-EE] F05 R1/R2 fix),软删流程(base.delete 不经 Base.delete)也被覆盖。
- 观察项(非 F05 范围,不计违反):nc_bases_v2 两行保留 deleted=True(CE 原生 base 软删设计,API 面已 404 不可见,实测 variables list of deleted base → 404);nc_base_users_v2 保留 3 行(CE 原生 base_users 管线,该表无 deleted 列)。均非 F05 diff 引入,F05 域数据无任何残留。

### T5 editor 降权 403 — PASS(实测)
- owner 邀请 f05r7a 进 base A roles=editor(200);editor token 实测:list 403 / get 403 / create 403 / update 403 / delete 403(五端点全 403)。
- 读码一致:acl.ts:268-271 baseVariableList/Create/Update/Delete 仅在 creator+ 权限数组;ProjectRoles.EDITOR include 块(acl.ts:531 起)无任何 baseVariable 条目。

## 结论

PASS — 56 项断言全过,0 error。第 7 轮最终确认:F05 Variables 功能收敛,满足连续 0 error pass 条件。

插曲说明(非违反):首轮边界用例 C-13/14/15 以小写 key 期待 200 得 400,经查证为 CE 模型层原生 KEY_REGEX 校验(BaseVariable.ts:216,非本轮 diff 引入),行为正确;修正用例为 UPPER_SNAKE key 后全过,不计 error。

测试资源已清理(两 base 已删,variables 零残留);f05r7a 账号沿用历轮惯例保留。
