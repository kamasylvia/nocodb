你是 NocoDB CE-EE fork 的 F09 Sync data **P2 生命周期 R3 站位回归**独立审查员，lane N。工作目录：/Volumes/UNITEK/Documents/Development/nocodb。

先读 `.work/ee-ce/r2-p2-lane-prompt.md`（验证范围全继承：R1 五 error 修复回归 + P1 全矩阵）、`.work/ee-ce/f09-p2-impl-report.md`、`.work/ee-ce/r2-p2-lane-prompt.md`（方法学注记）。审查基线 = 366e0b7045（R10 后零代码变更）；后端 :8080 运行修复后 dist（pid 33253）。

R2 五路全 PASS（0 error）；R3 = 连击 2/3 冲刺轮，同规格站位回归：paste 模式全链（uuid+密码凭据）、selected_fields 增删传播（增列须真实进数）、源列类型漂移、detach 转正、resync 复检、原子性、P1 全矩阵 + UI 活体（向导 paste 流/树菜单三态/Syncing 守卫/删除流三腿）。

纪律：只读审查禁改源码；禁 dev-backend*.sh/pkill/自愈/psql super；隔离禁读他路报告；账号 f09p2r3lN-*；camoufox session f09p2r3lN；UI/API 账号分离；测试数据全前缀测完删；质量门 tsc+jest+Vite URL；向导 SFC 路径 = components/project/Action/CreateNewSync.vue。报告 `.work/ee-ce/r3-p2-laneN.md`（沙箱禁写则 stdout 全文文末注明）。结论头：PASS / N error + N minor。
