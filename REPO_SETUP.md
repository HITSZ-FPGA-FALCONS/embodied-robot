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

> **更新（2026-09-16）**：团队决定直接开源，仓库已转为 **Public**。
> 注意：仓库目前**没有 LICENSE 文件**。public 但无许可证，法律上仍是「保留所有权利」，
> 别人没有使用授权——严格说这还不算开源，只是源码可见。需补一个许可证才算完成。
> 另需留意：板卡由指导老师提供，作品可能涉及学校/实验室成果归属，建议补许可证前跟老师确认一句。

## 已完成的初始化

```bash
git init
git add .
git commit -m "chore(repo): initialize competition repository"
git branch -M main
git remote add origin git@github.com:HITSZ-FPGA-FALCONS/embodied-robot.git
git push -u origin main
```

状态（2026-09-16）：仓库已建、已推送、已转 Public；14 个标签、10 条 Issue 已建。
`main` 尚未配置分支保护——GitHub Free 套餐的**私有**仓库不支持该功能，转 Public 后可配置。

## 上游资源与 Fork 策略

### 一个重要事实：ACG720 例程不在 git 仓库里

高云 / 小梅哥 / 芯路恒的 ACG720 官方资料**主要通过以下渠道分发，没有对应的 GitHub / Gitee 仓库**：

| 渠道 | 内容 |
|---|---|
| 小梅哥 B 站「2025 高云全新开源教学课程（for ACG720）」 | 视频教程：Gowin 软件安装、Modelsim、Verilog 流程、UART、按键消抖、SPI ADC/DAC、ROM/RAM、FIFO、时钟管理单元 |
| 芯路恒论坛 `corecourse.cn` | ACG720 自助服务手册、各类例程帖（USB-CDC、DDR3 缓存、数据采集、音频回环） |
| 百度网盘资料包 | 文档教材、例程源码、硬件图纸、开发软件 |
| 高云官网 / QQ 群 213923272 | 器件手册、IP、官方支持 |

**这意味着「把官方例程 Fork 进来」这条路对 ACG720 走不通**——没有 git 上游可 Fork。

实际做法：把需要的例程**下载后整理成本仓库内的子目录**，并在 `docs/UPSTREAM.md` 登记来源、获取日期、原始文件位置。这是「复制」而非「Fork」，所以登记更要写清楚，避免答辩时说不清哪些是自己写的。

Sipeed Tang 系列（选题二适配）在 `wiki.sipeed.com` 有 wiki，部分项目在 GitHub——若将来需要，那部分才是真正可 Fork 的。

### 可 Fork 的对象

| 类型 | 处理方式 |
|---|---|
| 上游确实是 git 仓库的开源项目 | Fork 到本 Organization，保留 upstream remote，修改在 Fork 自己的分支里做 |
| 官方例程（网盘/论坛分发） | 不可 Fork。下载后整理入 `third_party/` 或按模块拆分，在 `docs/UPSTREAM.md` 登记 |
| 独立验证性质的小实验 | 建独立仓库，如 `fpga-playground` |
| 与主项目解耦的训练工程 | 建独立仓库，如 `edge-ai-training` |

### 多仓库拆分时机

**不要第一天就把所有仓库建出来。等到有独立生命周期时再拆。**

判定标准：这个内容是否需要独立演进、独立协作、或独立对外发布？否则先放主仓库。

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
