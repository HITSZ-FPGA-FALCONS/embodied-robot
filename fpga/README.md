# fpga/ — 可综合逻辑与验证

本目录只放**最终作品真正使用的** FPGA 代码。一次性实验放 `exp/*` 分支或独立仓库，验证通过后再合进来。

## 目录约定

| 目录 | 放什么 | 不放什么 |
|---|---|---|
| `rtl/` | 可综合 RTL（`.v` / `.sv`） | testbench、厂商例程副本 |
| `tb/` | Testbench、仿真模型、激励文件 | 可综合逻辑 |
| `constraints/` | `.cst` 物理约束、`.sdc` 时序约束 | 个人临时引脚试验文件 |
| `ip/` | 本项目使用的 IP 配置说明与 `.ipc` | 厂商 IP 的完整源码副本 |
| `scripts/` | 综合、仿真、烧录、批处理脚本 | 工具链安装包 |

## 命名建议

RTL 模块用 `模块_功能.v`，例如：

```
rtl/pwm_gen.v               # PWM 生成
rtl/encoder_counter.v       # 正交编码器计数
rtl/imu_spi_master.v        # IMU SPI 主机
rtl/uart_tx.v / uart_rx.v   # 串口
rtl/edge_top.v              # 顶层
```

顶层模块名带 `_top` 后缀，便于一眼认出集成点。

## 硬性要求

1. **一个新模块必须先有 testbench 再上板。** 至少覆盖：正常输入、边界值、异常输入（如编码器抖动、UART 帧丢失）。
2. 所有模块的接口（时钟、复位、位宽、有效信号、单位、更新频率）写进对应的 Issue 或 `docs/architecture/`。
3. 跨时钟域的信号必须有明确的同步处理，并在代码注释里写明。
4. 不使用厂商 IP 的模块，在文件头注明来源（见 `docs/UPSTREAM.md`）。
5. 写完在 PR 里附**波形截图**。没有波形的 FPGA PR 视为未验证。

## 推荐开发顺序

```
接口定义 → RTL → Testbench → 波形 → 综合/实现 → 上板 → 逻辑分析仪/实测 → 集成
```

不能用「上板偶尔能跑」替代模块验证。

## 关于工具链

高云官方工具链为 **Gowin IDE / 云源软件**（`GowinSynthesis` 综合）。ACG720 板卡配套例程与引脚约束以厂家提供为准。

`.gitignore` 已忽略 `impl/`、`pnr/`、`*.fs` 等综合与布局布线产物——**不要提交这些**。约束文件 `.cst` / `.sdc` 必须提交。

> 若你们另外使用开源流程（yosys + nextpnr-gowin + openFPGALoader），请在本文件补充产物路径与脚本说明。
