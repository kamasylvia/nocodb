# r2-f07-rev-c（第 5 路交叉面复审 R2）

issues:

1. `packages/nocodb/src/models/BaseSnapshot.ts:158` : `deleteByBaseId` 全仓零调用（死代码）——原 base 删除（`Base.softDelete` 标准路径 + `Base.delete` 硬删）均未挂此钩子，`nc_snapshots` 登记行成孤儿（副本 base 同时残留为活的孤儿 base）。`src/models/Base.ts` 在工作树零改动（git diff 空，最后提交仍为 F05 6ab23da061）。GOAL-STATE「F07-R1 裁决与修复」第 4 条声称已挂（"挂 BaseSnapshot.deleteByBaseId（softDelete 已挂）✅"）与实际代码不符——修复丢失或从未落盘。建议：按 R1 决议把 `await BaseSnapshot.deleteByBaseId(context, baseId, ncMeta);` 挂入 `Base.softDelete`（`src/models/Base.ts:453` 旁，与 F05 `BaseVariable.deleteByBaseId` 同位）及 `Base.delete`（`:700` 旁），并更正 GOAL-STATE 该条。
2. `packages/nocodb/src/services/base-snapshots.service.ts:171-173` : deleteSnapshot 注释声称 "it also runs our deleteByBaseId hook, cleaning snapshot-base variables"——当前树中该 hook 无人调用，注释失实。建议：随 issue 1 挂钩后注释自洽；若不挂钩则改注释并删除死代码（二选一，R1 已裁决挂钩，建议挂钩）。
3. `.work/TODO.md:8` : F07 行文本过期（"R1 会审修复中"，实际 R2 会审运行中，与 GOAL-STATE 不同步）；`.work/TODO.md:10` : 残留第二条过期未勾 F07 backlog 行（"表已有，补 controller/service + UI"，已被 ：8 取代）——违反单状态源卫生。建议：:8 改为 R2 会审中，删除 :10 行。
4. `AGENTS.md:42`（§2.1 加密句）: "F05/F07 service 层有守卫（拒 secret 物料写入）" 对 F07 失实——F07 service 无加密守卫，且无需：create API 输入仅 title，duplicateBase 不复制 base variables（jobs/export-import 无 BASE_VARIABLES 引用）。建议：措辞改为 F05 限定（如 "F05 service 层有守卫…；F07 无 secret 物料输入通道（duplicateBase 不复制 variables）"）。

核对通过项（无误）：[CE-EE] 覆盖充分（改动文件均带标记；lang JSON 无注释位，与 F05 先例一致）；Api.ts/isEeUI/ncUtils 零触碰；acl 双侧一致（后端 base scope creator+ 四 op = 前端 creator block 四 op，controller @Acl 名称全对应，UI 三处门统一 baseSnapshotList）；快照可见性/restore/delete 语义与 §2.1 设计一致（跨 base 访问 notFound 防护、restore 新 base 不覆盖、删快照 softDelete 副本进 trash、15min 超时派生、无副本仍可删行）；秘钥不入 git（diff/新文件无凭证，.work 被 ignore，无硬编码 key）；tsc 0；jest 26/26（2 suites）；backend.log 尾 200 行仅 1 条预期内 UnauthorizedException（无 CacheMgr/TypeError，R1 期错误已消失）；§2.1 F07 设计段在且主体准确（含"副本是活 base"fork 限制说明）；History.vue manageSnapshot 外围门 = GOAL-STATE 已登记 backlog，不另计。
