你是 NocoDB CE-EE fork 的 F09 Sync data（P1 Table Sync）第 4 轮复审（R4）独立审查员。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。先读 `.work/ee-ce/r3-f09-lane-prompt.md`（R1-R4 同规格任务书），再读本增量。

## R4 增量附录（R3 修复批回归，commit 551694ecbe）

1. **is_private 分流**（R3 lane2 error 修复）：assertSourceReadAccess 现按源 base is_private 分流——私有 base 要求显式 base 级角色（零关系用户 404）；非私有 base 走 CE workspace 继承（workspace 级角色放行，零角色 no-access 仍拒）。验证：私有/非私有 base × 无关系用户 / workspace-creator 各组合的 source-schema 与 createSync 判定矩阵。
2. **jobs-map [CE-EE] 标记** ×3 在位（R1 m1 修复）。
3. console.debug ×4 残留清除（R1 m1/lane3 M4 修复——同步到最新源码核验）。
4. selectedFields:[] 空数组、createSync 非原子孤儿表——R2 已知 minor 沿袭（勿重复报，除非升级）。

## 全矩阵/质量门
同 r3-f09-lane-prompt.md 任务书（8 项清单 + 已知限制 + 非问题清单），质量门 tsc 0 + jest 41/41。

## 纪律
- 只读审查：严禁修改源码；只写报告与 /tmp 脚本
- 隔离：禁读他路报告；账号 f09r4lN-* 前缀；严禁 psql 提全局 super
- **严禁 dev-backend*.sh / pkill / 重启后端**；8080 异常每 60s 轮询
- camoufox --session f09r4lN 专属会话
- 报告落盘 `.work/ee-ce/r4-f09-laneN.md`
