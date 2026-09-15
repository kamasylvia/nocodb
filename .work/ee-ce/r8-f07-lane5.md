# r8-f07-lane5 — F07 第 8 轮收敛确认（第 5 路：int + rev）

日期：2026-09-12。对象：HEAD 6eb3b80c1d（F07+F10）+ c793dfcfa7（F01 修复）。工作树干净，无未跟踪文件。

## int（交叉抽验）— PASS

全链路实测（`.work/ee-ce/f07l5r8_int.sh` + `f07l5r8_db.py`，pg8000 直查 nocodb-dev，凭证运行时 Infisical 拉取）：

- P2 secret 物料安全：F05 API 建 secret variable（API_TOKEN）→ DB `nc_base_variables.value` 无明文（NC_CONNECTION_ENCRYPT_KEY 加密落库）；list 响应已掩码
- P3 快照：POST snapshots → 轮询至 completed；DB 核验 `nc_snapshots` 注册行存在、副本 base 存在且 deleted=false；**副本 base variables count=0**（快照无 secret 物料通道，AGENTS §2.1 声明属实）
- P4 restore：返回新 base id；DB 核验 `<orig> (restored)` 存在、表数=1
- P5 deleteSnapshot：注册行删除、副本 DB deleted=true、已删快照 GET=404
- P6 无孤儿：删 restore 产物与源 base 后 `nc_snapshots` 0 残留、无 live 引用 base
- 附加：删除**有快照的 work base** → 注册行清空 + 副本连带 softDelete（Base hook 实测，snapfe2yquhnvhzny5/plq3rtgelt3fywd）
- 权限抽查（`f07l5r8_editor403.sh`）：无 token list/create=401、坏 token=401、伪 snapshotId=404、伪 baseId=404；**editor 角色 create/list/delete=403，creator list=200**；跨用户删他人 base=403

## rev（交叉面终审）— PASS

- 安全语义：creator/owner 后端为 exclude 型（`src/utils/acl.ts` ProjectRoles.CREATOR exclude 不含 baseSnapshot* → 放行），editor 及以下 include 型无此 op → 403；前端 `lib/acl.ts` 仅 creator include 4 op，双侧一致。restore 全程不触工作 base（copy 副本再复制）；副本缺失时 restore=400（不泄内部 id 404）、deleteSnapshot 副本缺失仍 200；create mutex check-then-insert 竞态已在 service 注释声明 residual risk（最坏双副本无损坏）
- 一致性：`git diff bc409929da^ HEAD -- Api.ts ncUtils.ts` 为空（Api.ts/isEeUI 未动）；`// [CE-EE]` 标记覆盖全部 F07 源文件（lang JSON 无注释机制，豁免）；acl 双侧 4 op 同名同角色范围；noco.module/models/index 注册齐全；最新一次 rspack 编译干净（1 warning，无 error；log 中部编译 ERROR 均为历史 dev 中间态残留，其后有多次成功编译）
- 测试基建：`npx tsc --noEmit` exit 0；`pnpm test` jest **26/26**（2 suites）实跑通过；backend.log 无 F07 snapshot 相关运行时 error（grep snapshot/duplicate/restore error 零命中；2 个 CacheMgr dashboard appendToList ERROR 属 F10 范畴；1 个 JOB FAILED 是 export job 引用已删 base 走 dataHelpers R3 guard 的测试残留场景，非 F07 缺陷）
- 文档：AGENTS §2.1 四条声明逐条与实现/实测吻合（异步副本非冻结、restore=新 base、删快照=softDelete 副本+删行、variables 不复制→无 secret 通道）
- commit 前清单：`git status --porcelain` 全空（无未提交、无未跟踪）；HEAD 已含 6eb3b80c1d（F07+F10）与 c793dfcfa7（F01 修复），无遗留待提交面

## 观察（非 error，不计违反）

- restore 返回后产物 status 短暂显示 'job'（duplicate job 异步收尾），属 AGENTS §2.1 已声明的异步副本限制
- nuxt.config `allowedHosts=true` 仅 vite dev server 生效（生产不含 server 配置），已加 [CE-EE] 注释声明 dev-only
- 测试残留已全部清理（f07l5r8* base 0 live、快照行 0）

## 裁决

**PASS**（int PASS + rev PASS；0 error）
