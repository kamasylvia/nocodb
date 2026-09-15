# F07 R8 会审 — lane 3（int 抽验 + rev 后端终审）

日期: 2026-09-13。范围: commit 6eb3b80c1d / bc409929da（工作树干净）。隔离: 未读任何 r*.md。

## 裁决

**PASS**

## rev — R7 修复终核（6/6 到位）

1. **deriveStatus unified 重推导** ✅ `services/base-snapshots.service.ts:222-254` — 全状态（含 terminal）cache-free 重探测（getCopyBaseRow）；copy 缺失→error（已 error 则 null 短路）；status==='job' 先探测超时兜底（15min，探先行序保持 R2 修正）；list/get/restore 三调用点一致。
2. **getCopyBaseRow RootScopes.WORKSPACE** ✅ `service.ts:260-275` — metaGet2 第 2 参 RootScopes.WORKSPACE；`row.deleted === true` → null。
3. **ensureCopyExists** ✅ `service.ts:123-138` — restore 前强制调用（:162）；副本缺失→行置 error + 400 干净报错（不泄漏内部 id）。
4. **cleanupByBaseIdWithCopies** ✅ `models/BaseSnapshot.ts:182-208` — 逐行 softDelete 副本（Base.softDelete(context, baseId, ncMeta) 签名匹配，副本缺失 catch 继续）→ deleteByBaseId 删行；Base.ts 双挂钩在位（softDelete :458 / delete :711）。
5. **删快照守卫** ✅ `service.ts:187-220` — getCopyBaseRow 探测，副本存在才 softDelete，行必删（副本缺失不再 500）。
6. **title 截断** ✅ — create `service.ts:69` slice(0,150) + restore `:178` slice(0,150)。

静态: `npx tsc --noEmit` **EXIT=0**；`npx jest baseVariableValidators --runInBand --forceExit` **12/12 passed**。

全文再扫: controller（5 端点 ACL baseSnapshot*，creator+ 组 acl.ts:274-277）、noco.module.ts:333 注册、BaseSnapshot.ts insert cache 次序（先 get 后 appendToList）、update extractProps 白名单（title/status）、list 回源兜底、FE Snapshots.vue `res.data ?? []` 与裸数组响应匹配、restore 跳转 `/nc/{baseId}` —— 均无新问题。

## rev — 攻击性找茬

**无**（无可达链的 issue）。已排查并排除:

- `slice(0,150)` 孤立代理对 500 链: 实测不可达 —— 上游 base title 字符白名单（letters/numbers/space/hyphen/underscore/period/parens/&/,/'）+ maxLength 150 双验证把 emoji/代理对挡在建 base 层（实测 125ascii+emoji → 400）。快照 title 用户可控成分仅 base.title，纯白名单字符截断无代理对风险。
- deriveStatus list N+1 probe: 快照量小，性能小疵，非 error。
- restore 同步返回 job 态 base_id / restore 在飞删快照保护: 已有 backlog 记录，非本轮新发现。
- workspace 混淆 / 跨 base snapshot 访问: getSnapshotWithBaseCheck base_id 绑定 + ACL 层拦截。
- BaseSnapshot.delete 悬挂 cache 引用: deepDel CHILD_TO_PARENT 上游惯例，metaGet2 回源兜底。

## int — 全生命周期 1 轮 + 删源 base 清理（pg8000 直查 nocodb-dev）

run1（f07r8lane3_int.py）21 项: 19 PASS；2 FAIL 复测定谳为测试侧因素，产品无问题:

- A6 list 空: 脚本按 `{list}` 解析，API 实为裸数组 → retest R1b 证实裸数组含快照（FE 同款消费匹配）。
- A9 restored base 404: run1 时序缺陷 —— restore 后 ~5s 即删快照，restore 复制 job 在飞，源 copy 被 soft-delete → job 回滚（restored base 进 trash, status 残留 'job'）。干净时序 retest R2a-R2d 全过。

retest（f07r8lane3_retest.py）13/13 PASS:

- R1 快照 completed、list 裸数组含快照、title 持久化
- R2 restore: 200+base_id → base settles live（deleted=false, status≠job）→ 表在 → 3 行数据逐行匹配
- R3 restore 完成后删快照: 行 gone、副本 soft-delete、**restored base 存活**
- R4 清理: 删 restored base / 删源 base → 两者 nc_snapshots 行全清

删源 base 清理核验（run1 B 场景 + DB 直查）: DELETE base（baseSoftDelete → Base.softDelete 挂钩）→ nc_snapshots 行=0 ✅、快照副本 nc_bases_v2.deleted=true ✅、源 base deleted=true ✅。删快照路径: 行 gone + 副本 deleted=true（A11-A14/R3a-R3c 双证）。

测试资产已清理（本 lane 建的 base/快照全 deleted/删除；DB 中其它 f07r8* 残留属其它 lane 资产，未动）。

## 证据文件

- `.work/ee-ce/f07r8lane3_int.py` + `f07r8lane3_int_out.txt`（run1: 19/21, 2 FAIL 已定谳）
- `.work/ee-ce/f07r8lane3_retest.py` + `f07r8lane3_retest_out.txt`（retest: 13/13 PASS）
- `.work/ee-ce/r8lane3_tsc.txt`（tsc EXIT=0）
