# REVIEW-SCHEDULE — 复审阵容时间段配置（2026-09-15 用户指令）

> ⚠️ **临时覆盖（2026-09-15 22:50 用户指令）**：外部 CLI 阵容（omp/kilo/reasonix/pi）首秀不稳定（各路均出现启动失败或环境自愈互踩），**在用户重新配置复审方案之前，一律用 5 路 ZCode subagents**，不分时段。下表时间窗配置保留，恢复外部阵容以用户新指令为准。

> 巡检 automation 每整点触发，读本文件决定当次动作。阵容随时间窗切换。

## 时间窗 → 阵容

| 窗口 | 阵容 | 说明 |
|---|---|---|
| **23:00–次日 09:00** | 5 个 ZCode subagents | Agent tool × general-purpose × run_in_background，全同规格（全量集成+全 diff 复审+UI 段） |
| **09:00–14:00** | 外部复审 | 4 路 CLI（Bash run_in_background）+ 1 路 ZCode subagent 补位 |
| **14:00–18:00** | **停止** | 不派遣、不巡检动作；在飞路让其自然完成（不中断已派遣路） |
| **18:00–23:00** | 外部复审 | 同 09:00–14:00 |

## 外部复审阵容明细（lane 编号固定）

| lane | CLI | 命令形态 | 报告 |
|---|---|---|---|
| 1 | omp | `omp -p --auto-approve --thinking max "$(cat .work/ee-ce/r<N>-lane-prompt.md)"` | r<N>-f<NN>-lane1.md |
| 2 | kilo | `kilo run --auto --variant max "$(cat .work/ee-ce/r<N>-lane-prompt.md)"` | r<N>-f<NN>-lane2.md |
| 3 | reasonix | `reasonix -p --permission-mode bypassPermissions --output-format text "$(cat …)"`（**勿带 --effort max**，mimo 不支持） | r<N>-f<NN>-lane3.md |
| 4 | pi | `pi -p --mode text --no-session "$(cat …)"` | r<N>-f<NN>-lane4.md |
| 5 | ZCode subagent | Agent tool（run_in_background） | r<N>-f<NN>-lane5.md |

- CLI lane 模型：默认 clinepass/mimo-v2.5（omp 可用 opencode-go/muse-spark，配方见 GOAL-STATE muse 定案节）
- 路径正本：prompt 文件落 `.work/ee-ce/r<N>-lane-prompt.md`，CLI 命令用 `"$(cat …)"` 注入，禁手写内联转义
- 阵容本质两套：**subagents 全同规格** vs **外部 4 CLI + subagent 补位**——规格（测试矩阵/报告格式/裁决规则）两套完全一致，只是执行体不同

## 巡检规则（每整点）

1. 14:00–18:00 → 无动作（记录一行即可）
2. 在飞路存活检查：报告文件 mtime / 进程探活；卡死路重试 1 次，单路缺席不拖死全局
3. 5/5 报告齐 → 裁决（≥2 路同判 error = 必修 + 连击重开；单路属实实测后也修不计；连续 3 轮 0 error → pass）
4. 无在飞路且非停止窗 → 按当前窗口阵容派下一轮（R<N+1>，prompt 文件先落盘）
5. 路在飞期间禁改任何仓库源码（rspack 热重建会毁掉在飞路测试）
6. 每次动作后更新 GOAL-STATE.md；裁决/修复由巡检会话执行，修完即 commit（main）
