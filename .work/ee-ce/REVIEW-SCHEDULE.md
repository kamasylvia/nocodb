# REVIEW-SCHEDULE — 多路复审方案（2026-09-16 22:xx 用户指令，固化版）

> 巡检 automation 每整点触发，读本文件决定当次动作。**本表为固化配置，取代此前一切临时覆盖。**

## 时间窗 → 阵容

| 窗口 | 阵容 |
|---|---|
| **23:00 – 次日 09:00** | 5 个 ZCode subagents（全同规格） |
| **14:00 – 18:00** | **暂停**（无动作；在飞路自然完成不中断） |
| **09:00 – 14:00 与 18:00 – 23:00** | **按全局 AGENTS.md 复审方案**：外部阵容 omp / pi / kilo / reasonix（+ ZCode subagent 补位，有效 ≥4 路）。**不显式声明 provider / model / thinking**——各路 agents 自身配置已就绪，直接用默认。 |

## 外部路命令形态（无 provider/model/thinking 声明）

| lane | CLI | 命令 |
|---|---|---|
| 1 | omp | `omp -p --auto-approve "$(cat .work/ee-ce/r<N>-<FF>-lane-prompt.md)"` |
| 2 | kilo | `kilo run --auto "$(cat …)"` |
| 3 | reasonix | `reasonix -p --permission-mode bypassPermissions --output-format text "$(cat …)"` |
| 4 | pi | `(export CLINE_API_KEY="$(python3 -c "import json;print(json.load(open('$HOME/.pi/agent/auth.json'))['clinepass'])")"; pi -p --mode text --no-session "$(cat …)")` |
| 5 | ZCode subagent | Agent tool（run_in_background，同规格） |

- 全部 Bash run_in_background（ZCode orchestrator 模式）；prompt 文件落盘后 `"$(cat …)"` 注入，禁手写内联转义。
- **启动即错不重试声明**：若某路因默认配置启动失败，重试 1 次后记 E3 缺席，不拖死全局。
- 共享 owner 账号 signin 互踢为已知环境约束——各路用任务书附录指定的专属账号。

## 巡检规则（每整点）

1. 14:00–18:00 → 停止窗：无动作，落一行 patrol 记录即结束。
2. 在飞路存活：报告 mtime + 派发时长；卡死（>90min 零产出且进程不在）重试 1 次，单路缺席不拖死全局。
3. 报告齐 5/5 → 裁决（≥2 路同判 error = 必修 + 连击重开；单路属实实测后也修不计；连续 3 轮 0 error → pass）。
4. 无在飞路且非停止窗 → 按当前窗口阵容派下一轮（prompt 文件先落盘）。
5. 在飞期间禁改源码（后端 rspack / 前端 HMR 都会毁在飞测试）。
6. 每次动作后更新 GOAL-STATE；修复 commit 只落 main。
