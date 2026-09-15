# r6-f05-int-b — F05 R6 集成测试·对抗面（第 2 路）

PASS

## 验收证据

环境：dev server 127.0.0.1:8080，DB nocodb-dev（qnap.elf-balance.ts.net:5432，Infisical KDL DB_*，运行时拉取）；主账号 signup 400（已存在，org-level-viewer 无 baseCreate）→ 按预案回落 f01e2e@ce-ee.local（token 实测有效）；资源前缀 f05r6b_，测完已删（DB prefix residue=0）。

### 1. 缓存守卫 — PASS

- secret GET×5：`t1.secret_get_x5` 5 次明文恒等（cache-secret-1789179125），无双解密漂移。
- list/GET 交替×6：`t1.list_get_alternate_x6` list 面 secret value 恒为 undefined（masked）、GET 面恒为明文，无串扰。
- PATCH 后 GET×3：`t1.patch_then_get_x3` 3 次恒为新值 cache-rotated-1789179125。
- PLAIN 行 GET×5：`t1.plain_get_x5` 恒定。

### 2. 加密状态机四步三面核 — PASS

- API 面（run1）：`t2.step0.create_text`→`t2.step1.flip_to_secret_api`（value=V1 保持）→`t2.step2.rotate_secret_api`→`t2.step3.flip_to_text_api` 全 200 语义正确。
- DB 面（t3db，pg8000 直查 nc_base_variables）：step1 落库密文 `U2FsdGVkX19X30WW...`≠明文；step2 轮换后密文变化且≠新明文；step3 flip→text 落库还原明文 `dbface-two-1789179265`；step4 flip→secret 重新加密，API GET 两次恒返回明文（`t2db.step4.api_plaintext` / `api_repeat`）。6/6 PASS。
- 响应面：`t2.faces.response` — get/list 响应 JSON 无 `U2FsdGVk` 密文泄漏；list 对 secret 行 value/default_value 均 strip；单变量 GET 返回正确明文。

### 3. 非法输入矩阵 + PATCH 语义 — PASS

- 四轴全 400（23/23，无 500）：key 轴 9 项（missing/null/num/empty/lower/dash/space/起始数字/256 长）；value 轴 5 项（num/obj/arr/bool/65537 长）；type 轴 5 项（bogus/num/obj/大写"SECRET"/bool）；description 轴 3 项（obj/num/arr）。
- 边界：key 255 字符 200、value 65536 字符 200（`t3.boundary.*`）。
- 无行泄漏：23 次非法 create 前后 list 计数不变（`t3.no_rows_leaked`）。
- PATCH 语义：`value:null`→清空为 ''（`t3b.patch.null_clears`）；desc-only 正常（`t3b.patch.desc_only`）；`description:null` 清空；同 key echo 200；改 key 400（`t3b.patch.key_change_400`）；空 body 400 "Nothing to update"；未知 id 404；secret 行 desc-only PATCH 不触发加密守卫误拒、value 不变（`t3b.patch_desc_on_secret`）。

### 4. 删 base 零残留 + 并发同 key — PASS

- 并发同 key 8 线程：恰好 1×200 + 7×400（msg="Variable key ... already exists in this base"），0×5xx，落库单行（`t4.race.*` 4 项）。
- 删 base：3 变量（含 1 secret）+ 删 base 200 后直查 DB `nc_base_variables where base_id=...` = 0（`t4db.zero_residue_after_base_delete`）；此前轮 3 个已删 base 复查残留 0（`t4db.zero_residue_prev_bases`）；全表 f05r6b% 残留 0；孤儿行（base 已不存在的变量）0（nc_bases_v2 join 复核）。

### 5. 权限 401/403 矩阵 — PASS

- 无 token：list/get/create/patch/delete 全 401（5 项）；伪造 token 401。
- viewer（invite 200，roles=viewer）：五操作全 403（5 项）；editor（invite 200，roles=editor）：五操作全 403（5 项）。403 为角色 ACL 拒绝（成员资格已在 base，与 acl.ts creator+（exclude 模式）设计一致）。
- owner：全操作 200（`t5.owner.get` 等）。
- 跨 base 隔离：他 base URL GET/PATCH 该变量 → 404 "Variable not found"（`t5.crossbase.*`）。

## 备注（非 issue）

- 测试中一次瞬发 401（t3db 首跑 secret create）：f01e2e 为多路共用的回落账号，疑似并行会话 signin 使 token_version 轮换；同脚本重跑全绿（含 me probe 200），判环境噪音非 fork 缺陷。
- 清理：全部 f05r6b_ 变量/base 已删，API cleanup 0 错误 + DB prefix residue=0 + orphans=0 复核。
- 产物：`.work/ee-ce/f05r6b_run1.py`（API 70/70 PASS）、`.work/ee-ce/f05r6b_t3db.py`（DB 面 12/12 + 补查 2 项 PASS）、`f05r6b_ctx.json`。
