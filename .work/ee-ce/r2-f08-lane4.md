# F08 R2 lane4 复审报告(camoufox UI 实测 + 代码辅审)

**结论:PASS**(0 error)

审查对象:6aea3db097(F08 实现)+ 2a86eb7d6c(R1 修复),重点 R1 后新增 UI 面。
测试 base:`F08R2UI-24922` / `p7ci9e80gkf5da2`(nocodb-dev,workspace w9qi3ljd)。
工具链:camoufox MCP 拒 localhost(`Blocked private network target`)→ 按协议回落本机 camoufox-cli,双 session(owner/member)+ 补充对照 session(collab/outsider)。

---

## 代码复审(辅,无 error)

- `packages/nc-gui/components/dashboard/settings/base/Access.vue`:`selectType` 有 `isUpdating` 竞态守卫 + `val === isPrivate.value` 严格布尔比较;PATCH 成功后乐观写回 `(base.value as any).is_private`;失败走 `extractSdkResponseErrorMsg` toast。逻辑正确。
- `packages/nc-gui/store/base.ts:81`:`isPrivateBase = !!(base.value as any)?.is_private`;`base.value` 经 `basesStore.loadProject`(`api.base.read` spread)填充,实测 GET `/api/v2/meta/bases/:id` 回传 `is_private`(true/false 双向验证),接线成立。`as any` 因 SDK Base 类型暂无该字段,可接受的取舍。
- `packages/nc-gui/composables/useEeConfig.ts`:`blockPrivateBases→false`,仅解此一 gate,无误翻其它。
- `packages/nc-gui/components/dashboard/settings/base/index.vue`:门条件 `!blockPrivateBases && isUIAllowed('manageBaseType')`(替代原 `isEeUI && … && showEEFeatures`);`allTabs` 含 `baseType` 且 `getDefaultTab` 优先返回;无权限时 `selectMenu('baseType')` 拦截。
- `packages/nc-gui/lib/acl.ts:156`:`manageBaseType` 放 CREATOR.include;`roleScopes` 基座角色序 NO_ACCESS→VIEWER→COMMENTER→EDITOR→CREATOR→OWNER 按 include 逐级上溯,OWNER 继承成立(SUPER_ADMIN 走 `'*'`)。注释「OWNER/ADMIN inherit via superAdmin '*'」表述不准(实际走 role-scope include 合并,'*' 只覆盖 SUPER_ADMIN),仅注释瑕疵、行为正确。
- i18n:8 个新 key(`general.baseType`/`labels.workspace`/`title.privateBase`/`title.baseTypeSettings{Default,Private}Subtext`/`title.baseTypeTabSubtext`/`msg.info.baseTypeChangedTo{Private,Workspace}`)en + zh-Hans 双语齐备。
- 消费点核查:`isPrivateBase` 在 ShareBase.vue(150/166)、SharePage.vue、View.vue(share/base 两处)、AccessSettings.vue 的门控均已接真值。

## UI 实测逐项

| # | 步骤 | 结果 | 证据 |
|---|---|---|---|
| 1 | owner 进 base settings → Base Type tab 存在可点,两卡(Workspace/Private),初始 Workspace 选中 | PASS | `.work/ee-ce/ui-f08-r2-l4-typetab.png` |
| 2 | 点 Private → toast「Base type changed to private. Only invited collaborators can…」+ Private 卡选中态 | PASS | `.work/ee-ce/ui-f08-r2-l4-type-private.png`(含 toast) |
| 3 | 刷新后状态保持(UI Private checked + API GET `is_private:true`) | PASS | snapshot `[checked]` + curl 回读 |
| 4 | 切回 Workspace → toast「Base type changed to workspace…」+ `is_private:false` | PASS | `.work/ee-ce/ui-f08-r2-l4-type-workspace-toast.png`(含 toast) |
| 5 | 可见性 delta:outsider(ws-level-editor 继承,无 base 角色)workspace 态见 → private 态不见;collab(显式 editor)private 态仍见 | PASS | 列表 grep 计数 1→0 / 恒 1 |
| 6 | Share 对话框:private 态 Share Base 开关消失(`role=switch` 计 0),替换为「This base is set as Private and cannot be shared publicly…」+ Manage Base Access 按钮;workspace 态开关恢复(计 1) | PASS | `.work/ee-ce/ui-f08-r2-l4-share-private.png` |
| 7 | outsider 直链私有 base URL → 重定向 `/nc` + toast「Base 'p7ci9e80gkf5da2' not found」+ Bases(0),零数据泄漏 | PASS | snapshot 文本证据 |
| 8 | zh 语言:面板渲染「项目类型/工作区/私有项目」+ 描述,toast/Share 对话框均 zh,无 key 裸露 | PASS | `.work/ee-ce/ui-f08-r2-l4-typetab-zh.png` |
| 9 | console error / 网络 5xx:SPA 内注入 hook(`console.error` + fetch/XHR ≥500)后跑两轮 private↔workspace 切换,回读 `errs=[] fives=[]` | PASS | hook 回读 JSON |

补充观察(非 error):
- member(super 提权 + editor)直链私有 base 正常进入 — super 旁路,预期行为,非泄漏。
- 任务书步骤 3 原表述「member 不见→切回复见」存在前提混淆:member 同时被邀请 editor(协作者应恒见)且被提权 super(旁路)。已用 collab/outsider 双对照分离语义并补 `workspace-level-editor` 完成 delta 闭环。
- 本 dev 实例 Default Workspace 对全员继承 `workspace-level-no-access`(成员页「Role inherited from workspace」),普通用户对 workspace-shared base 也不可见 — 既有配置,与 F08 过滤无关。
- 环境 E3(有诊断,不算 error):① camoufox MCP 拒 localhost,已回落 camoufox-cli;② dev JWT TTL 短(约数分钟),测试中两次被踢回 /signin,重登恢复,与 F08 无关。

## 遗留( cosmetic,不判违反)

- `packages/nc-gui/lang/en.json` / `zh-Hans.json`:commit 丢失文件末尾换行(`\ No newline at end of file`)。
- `acl.ts` 注释对 OWNER 继承机制表述不准(见上),可顺手修正。

## 测试账号(一次性,可弃)

f08r2l4-owner-24922 / f08r2l4-member-24922 / f08r2l4-collab-1077 / f08r2l4-out-1077 @test.local(base F08R2UI-24922 留存 nocodb-dev,outsider 被临时提为 workspace-level-editor,已记录)。
