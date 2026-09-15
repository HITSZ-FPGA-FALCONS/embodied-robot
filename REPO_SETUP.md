# HITSZ-FPGA-FALCONS 主仓库搭建说明

## 当前建议

Organization：`HITSZ-FPGA-FALCONS`

首个主仓库建议命名：

```text
embodied-robot
```

描述建议：

```text
FPGA real-time perception and autonomous control system for the 2026 National Embedded Competition (Gowin Track 3).
```

建议先设为 **Private**，等代码、许可证、比赛公开要求明确后再决定是否公开。

## 创建仓库后

把本模板内容提交到仓库根目录：

```bash
git init
git add .
git commit -m "chore(repo): initialize competition repository"
git branch -M main
git remote add origin <你的仓库地址>
git push -u origin main
```

## GitHub 设置建议

### Branch protection / ruleset

如果 Organization 权限允许，给 `main` 设置：

- 禁止 force push；
- 禁止删除；
- 合并前至少 1 人 review（若初期觉得太重，可先不强制，但团队约定保留）；
- 后续有 CI 后再开启 required status checks。

### Project 看板

建议列：

```text
Backlog
Ready
In Progress
Review / Verify
Done
```

### Labels

建议创建：

```text
area:fpga
area:control
area:sensor
area:vision
area:ai
area:hardware
area:docs

type:task
type:bug
type:experiment

priority:P0
priority:P1
priority:P2

status:blocking
```

## 推荐的 Organization 多仓库布局

```text
HITSZ-FPGA-FALCONS/
├─ embodied-robot              # 最终参赛主仓库
├─ fpga-playground             # FPGA 小实验（可选）
├─ edge-ai-training            # AI 数据/训练工程（后期可建）
├─ robot-hardware              # 若硬件规模变大再拆
├─ competition-docs            # 若文档独立协作需要再拆
├─ gowin-xxx-example           # 官方例程 Fork
└─ other-upstream-project      # 第三方 Fork
```

不要第一天就把所有仓库都创建出来。**有独立生命周期时再拆。**

## 第一批 Issue 建议

1. `[Task] 跑通 Gowin 工具链与开发板最小例程`
2. `[Task] 完成 PWM RTL + Testbench`
3. `[Task] 完成正交编码器计数 RTL + Testbench`
4. `[Task] 确认底盘、电机、编码器与驱动方案`
5. `[Task] 确认 IMU / 测距传感器方案`
6. `[Task] 绘制系统架构 v0.1 与接口边界`
7. `[Exp] 验证差速底盘原地旋转与视觉周向搜索可行性`

其中 1–6 是本周主线；7 只需要做方案级验证，不要现在演化成完整 AI 子项目。

## 三人协作的关键原则

> 分工不是切割知识，而是划分当前负责人。

每个人都要具备基本 Verilog、仿真、Git 和接口调试能力；但同一时刻只能有明确 owner 推进一个模块。

最终参赛时，任何关键模块至少要有两个人知道：

- 它做什么；
- 输入输出是什么；
- 怎么验证；
- 出问题如何回退。
