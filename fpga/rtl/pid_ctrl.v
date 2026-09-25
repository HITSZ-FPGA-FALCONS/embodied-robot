// ============================================================================
//  pid_ctrl —— 单侧轮速 PID 控制器
// ----------------------------------------------------------------------------
//  功能：每个控制周期比较"目标速度"和"实测速度"，算出一个 PWM 占空比。
//
//      目标 v ──→( − )──→ PID ──→ duty + dir ──→ pwm_gen ──→ 电机
//                 ↑                                            │
//                 └────────── encoder_counter ←────────────────┘
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ 先别读实现。这个模块有三个坑，每一个都是"车能跑但跑不对"的典型：
//
//    Q1. 输出必须限幅。不限幅会发生什么？
//        （提示：不是"输出太大"，是"松开指令后车还在冲"）
//
//    Q2. 积分项在 en=0 时必须清零。不清会怎样？
//        （提示：想想"重新使能的瞬间"）
//
//    Q3. 目标速度可以是负的（倒车）。一个只输出 0~PERIOD 的 duty
//        够用吗？缺了什么？
//
//  ────────────────────────────────────────────────────────────────────────────
//  编码规范：遵循 .claude/skills/shared/CodingStyle.md（同步复位 + RS_LV）
// ============================================================================

`timescale 1ns / 1ps

module pid_ctrl #(
    parameter DUTY_W     = 12,      //! duty 输出位宽
    parameter DUTY_MAX   = 2500,    //! duty 上限，**必须等于 pwm_gen 的 PERIOD**
    parameter GAIN_SHIFT = 8,       //! 增益定点位数：实际增益 = 参数值 / 2^GAIN_SHIFT
    parameter KP         = 256,     //! 比例增益（Q8：256/256 = 1.0）
    parameter KI         = 32,      //! 积分增益（Q8：32/256 = 0.125）
    parameter KD         = 0,       //! 微分增益（默认 0 = 关掉，见 §使用约束）
    parameter ACC_MAX    = 200000,  //! 积分累加限幅（防积分饱和）
    parameter RS_LV      = 0        //! reset active level (0 = active-low)
) (
    input  wire                  clk,      //! 系统时钟
    input  wire                  rst_n,    //! 复位（极性由 RS_LV 决定）
    input  wire                  en,       //! 0 = 复位积分项并输出 0
    input  wire                  tick,     //! 控制周期使能（约定 20 ms / 50 Hz）
    input  wire signed [15:0]    target,   //! 目标速度 mm/s（有符号，可负 = 倒车）
    input  wire signed [15:0]    actual,   //! 实测速度 mm/s（有符号）
    output reg  [DUTY_W-1:0]     duty,     //! PWM 占空比，**恒为非负**（0 ~ DUTY_MAX）
    output reg                   dir       //! 方向：0 = 正转，1 = 反转
);

    // ── 误差 ────────────────────────────────────────────────────────────────
    // Q1/Q3 的铺垫：误差是**有符号**的。目标 500、实测 100 → 误差 +400。
    wire signed [16:0] err = target - actual;

    // ── 三项 ────────────────────────────────────────────────────────────────
    //
    //  比例项 P：误差越大，推得越猛。          负责"响应快"
    //  积分项 I：把历史误差攒起来，消除稳态差。 负责"最终能到位"
    //  微分项 D：误差变化越快，刹车越早。       负责"不过冲"（但噪声敏感）
    //
    //  ⚠️ 输入是 mm/s，增益是**定点小数**（Q8：值 / 256）。
    //     所以最后要右移 GAIN_SHIFT 位才回到"duty 计数值"的量纲。
    //     忘了移位 = 增益差 256 倍，现象是"一给目标就满输出"。
    reg  signed [16:0] err_prev_ff;             // 上一拍的误差（给 D 用）
    reg  signed [31:0] acc_ff;                  // 积分累加器

    // ⚠️ 增益必须转成**有符号**再参与运算。
    //    Verilog 里 `无符号 × 有符号` 会让**整个表达式变成无符号**，
    //    负误差就会按无符号解释成一个大正数 —— 表现是"倒车时满油门往前冲"。
    //    这是 Verilog 最阴的一类坑：编译不报错，仿真结果错得离谱。
    localparam signed [31:0] KP_S = KP;
    localparam signed [31:0] KI_S = KI;
    localparam signed [31:0] KD_S = KD;
    localparam signed [31:0] DMAX = DUTY_MAX;   // 限幅值也转成有符号，避免三元表达式被拉成无符号

    wire signed [16:0] err_d = err - err_prev_ff;

    wire signed [31:0] term_p = KP_S * err;
    wire signed [31:0] term_i = KI_S * acc_ff;
    wire signed [31:0] term_d = KD_S * err_d;

    wire signed [31:0] u_raw    = term_p + term_i + term_d;
    wire signed [31:0] u_shift  = u_raw >>> GAIN_SHIFT;   // 算术右移，保留符号

    // ── 限幅（Q1 的答案）────────────────────────────────────────────────────
    //
    //  不限幅的后果不是"输出太大"，而是**积分饱和**：
    //  目标一直达不到时积分项无限累积，等条件满足了，积分项要花很久才能
    //  退回去 —— 表现就是**松开指令后车还在冲**。这是 PID 最经典的故障。
    wire sat_hi = (u_shift >  DMAX);
    wire sat_lo = (u_shift < -DMAX);

    wire signed [31:0] u_sat = sat_hi  ?  DMAX
                             : sat_lo  ? -DMAX
                             :           u_shift;

    // ── 方向与幅值（Q3 的答案）──────────────────────────────────────────────
    //
    //  一个 0~PERIOD 的 duty **不够用** —— 它只能表达"多快"，表达不了"往哪边"。
    //  倒车时 duty 只能到 0，车就停住了，永远退不回来。
    //  所以必须把符号单独引出来，这就是 `dir`。
    //
    //  ⚠️ 取绝对值**不能**写成 `u_sat[DUTY_W-1:0]` —— 那只是截低位，
    //     负数的低 12 位是个大正数。必须真的取负号。
    wire signed [31:0] u_mag = (u_sat < 0) ? -u_sat : u_sat;
    // u_sat 已限幅到 ±DUTY_MAX，且 DUTY_MAX < 2^DUTY_W，所以取位不会溢出

    // ── 每个控制周期更新一次 ────────────────────────────────────────────────
    always @(posedge clk)
        if (rst_n == RS_LV) begin
            acc_ff      <= 32'sd0;
            err_prev_ff <= 17'sd0;
            duty        <= {DUTY_W{1'b0}};
            dir         <= 1'b0;
        end
        else if (!en) begin
            // Q2 的答案：不清积分项，重新使能的那一瞬间，
            // 之前攒下的积分会**立刻**变成一个巨大的输出 —— 车会猛冲一下。
            acc_ff      <= 32'sd0;
            err_prev_ff <= 17'sd0;
            duty        <= {DUTY_W{1'b0}};
            dir         <= 1'b0;
        end
        else if (tick) begin
            // ⚠️ 积分更新用**条件积分（anti-windup）**：
            //    输出已经饱和、且误差还想把它推得更饱和时，就**停止累积**。
            //    这样积分项永远不会跑到"退不回来"的地步。
            if (!(sat_hi && err > 0) && !(sat_lo && err < 0)) begin
                // 累加后再限幅，双保险
                if (acc_ff + err > ACC_MAX)       acc_ff <=  ACC_MAX;
                else if (acc_ff + err < -ACC_MAX) acc_ff <= -ACC_MAX;
                else                              acc_ff <= acc_ff + err;
            end

            err_prev_ff <= err;

            duty <= u_mag[DUTY_W-1:0];
            dir  <= (u_sat < 0);
        end

endmodule
