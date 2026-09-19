// ============================================================================
//  tb_pwm_gen —— pwm_gen 的 testbench
// ----------------------------------------------------------------------------
//  验证目标（每一条都要有对应的检查，不能只看波形）：
//
//    1. 复位后 pwm 为低
//    2. duty = 0      → 恒低（0%）
//    3. duty = PERIOD → 恒高（100%）
//    4. duty = PERIOD/2 → 一个周期里恰好一半是高电平
//    5. duty = 3      → 一个周期里恰好 3 拍高电平（不是 2 也不是 4）
//    6. PWM 周期恰好等于 PERIOD 个时钟（频率对不对）
//    7. en = 0 时 pwm 立即变低
//
//  运行： sim.bat fpga\tb\tb_pwm_gen.v fpga\rtl\pwm_gen.v
//
//  ────────────────────────────────────────────────────────────────────────────
//  这个 TB 的测量思路（比"看波形觉得对"可靠得多）
//  ────────────────────────────────────────────────────────────────────────────
//  PWM 的规格是"每个周期里有 duty/PERIOD 的时间是高电平"。
//  所以最直接的验证方法是：
//
//      数一整段【整数个周期】里，pwm 一共高了多少拍。
//
//  只要窗口长度是 PERIOD 的整数倍，结果就精确等于 周期数 × duty。
//  这样测出来的不是"看起来差不多"，而是一个可以写进检查语句的数字。
//
//  ⚠️ 注意窗口必须是 PERIOD 的整数倍。如果随便数 37 拍，
//     窗口就会横跨半截周期，结果随相位漂移——那不是被测设计的问题，
//     是测试方法的问题。
// ============================================================================

`timescale 1ns / 1ps

module tb_pwm_gen;

    // 测试用参数：比例 PERIOD = 1000/100 = 10，跑得快，便于人脑核对
    localparam CLK_HZ = 1000;
    localparam PWM_HZ = 100;
    localparam PERIOD = CLK_HZ / PWM_HZ;    // = 10
    localparam DUTY_W = 4;                  // 要装得下 PERIOD=10，4 位最大 15 ✓
    localparam [DUTY_W-1:0] PMAX = PERIOD;  // PERIOD 的 DUTY_W 位形式，方便下面直接用

    reg               clk   = 1'b0;
    reg               rst_n = 1'b0;
    reg               en    = 1'b0;
    reg  [DUTY_W-1:0] duty  = {DUTY_W{1'b0}};
    reg               dir   = 1'b0;
    wire              pwm;
    wire              dir_o;

    pwm_gen #(
        .CLK_HZ (CLK_HZ),
        .PWM_HZ (PWM_HZ),
        .DUTY_W (DUTY_W)
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .duty  (duty),
        .dir   (dir),
        .pwm   (pwm),
        .dir_o (dir_o)
    );

    always #5 clk = ~clk;                   // 周期 10 ns

    integer errors = 0;

    // ── 检查任务 ────────────────────────────────────────────────────────────
    task check;
        input        cond;
        input string msg;
        begin
            if (!cond) begin
                $display("  FAIL: %s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // ── 测量任务：在 periods 个完整周期里，数 pwm 高了多少拍 ────────────────
    //
    //  期望值恒为  periods * d
    //
    //  ⚠️ 关于采样时刻：一个 always/for 里写 @(posedge clk) 之后读 pwm，
    //     读到的是【这一拍更新前】的值（和 tb_clk_div.v 里讲的是同一件事）。
    //     这不是 bug：窗口长度是 PERIOD 的整数倍，整体平移不影响总数。
    integer hi;
    task measure;
        input [DUTY_W-1:0] d;
        input integer      periods;
        integer k;
        begin
            duty = d;
            repeat (PERIOD) @(posedge clk);     // 先等一个完整周期，让新 duty 生效
            hi = 0;
            for (k = 0; k < periods * PERIOD; k = k + 1) begin
                @(posedge clk);
                if (pwm) hi = hi + 1;
            end
        end
    endtask

    // ── 周期监视器：检查相邻两次上升沿之间是否恰好隔 PERIOD 拍 ───────────────
    integer cyc        = 0;
    integer prev_rise  = -1;
    integer bad_period = 0;
    reg     pwm_d      = 1'b0;
    reg     mon_en     = 1'b0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (mon_en && pwm && !pwm_d) begin
            if (prev_rise >= 0 && (cyc - prev_rise) != PERIOD) begin
                bad_period = bad_period + 1;
                $display("    PWM 周期异常: 第 %0d 拍 → 第 %0d 拍 = %0d，应为 %0d",
                         prev_rise, cyc, cyc - prev_rise, PERIOD);
            end
            prev_rise = cyc;
        end
        pwm_d = pwm;
    end

    integer i;

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_pwm_gen);

        $display("=== pwm_gen 测试开始 ===");
        $display("  CLK_HZ=%0d  PWM_HZ=%0d  →  PERIOD=%0d  DUTY_W=%0d",
                 CLK_HZ, PWM_HZ, PERIOD, DUTY_W);
        $display("");

        // ── 用例 1：复位期间 pwm 必须为低 ───────────────────────────────────
        rst_n = 1'b0; en = 1'b0; duty = 0;
        repeat (3) @(posedge clk);
        #1;
        check(pwm === 1'b0, "复位期间 pwm 应为低");
        $display("  [1] 复位期间 pwm=0 ................... %s", pwm === 1'b0 ? "OK" : "FAIL");

        // 释放复位并开启输出
        rst_n = 1'b1; en = 1'b1;
        repeat (2) @(posedge clk);

        // ── 用例 2：duty = 0 → 恒低 ─────────────────────────────────────────
        measure(4'd0, 10);
        check(hi == 0, $sformatf("duty=0 时应恒低，实测高了 %0d 拍", hi));
        $display("  [2] duty=0      高电平 %0d 拍 (期望 0) ..... %s", hi, hi == 0 ? "OK" : "FAIL");

        // ── 用例 3：duty = PERIOD → 恒高（100%）────────────────────────────
        measure(PMAX, 10);
        check(hi == 10 * PERIOD,
              $sformatf("duty=PERIOD 时应恒高 %0d 拍，实测 %0d", 10 * PERIOD, hi));
        $display("  [3] duty=PERIOD 高电平 %0d 拍 (期望 %0d) ..... %s",
                 hi, 10 * PERIOD, hi == 10 * PERIOD ? "OK" : "FAIL");

        // ── 用例 4：duty = PERIOD/2 → 50% ──────────────────────────────────
        //     这一条最关键：50% 是最容易被"看起来对"蒙混过去的比例。
        measure(PMAX / 2, 10);
        check(hi == 10 * PERIOD / 2,
              $sformatf("duty=PERIOD/2 时应高 %0d 拍，实测 %0d", 10 * PERIOD / 2, hi));
        $display("  [4] duty=PERIOD/2 高电平 %0d 拍 (期望 %0d) %s",
                 hi, 10 * PERIOD / 2, hi == 10 * PERIOD / 2 ? "OK" : "FAIL");

        // ── 用例 5：duty = 3 → 一个周期恰好 3 拍 ───────────────────────────
        measure(4'd3, 10);
        check(hi == 30, $sformatf("duty=3 时应高 30 拍，实测 %0d", hi));
        $display("  [5] duty=3      高电平 %0d 拍 (期望 30) .... %s", hi, hi == 30 ? "OK" : "FAIL");

        // ── 用例 6：PWM 周期必须恰好 PERIOD 个时钟 ──────────────────────────
        //     方法：连续观察 10 个周期，看相邻上升沿间隔是否恒为 PERIOD。
        //     用例 2~5 只能证明"占空比对的"，不能证明"频率对的"——
        //     一个慢 10 倍的 PWM 也能通过占空比检查。所以这一条必须单独做。
        duty = 4'd1;                        // 1/10 占空比，每周期有一个干净的上升沿
        repeat (PERIOD * 2) @(posedge clk);
        prev_rise = -1; bad_period = 0; mon_en = 1'b1;
        repeat (PERIOD * 10) @(posedge clk);
        mon_en = 1'b0;
        check(bad_period == 0,
              $sformatf("相邻上升沿间隔应恒为 %0d 拍，有 %0d 次不符", PERIOD, bad_period));
        $display("  [6] PWM 周期异常次数 %0d (期望 0) ...... %s", bad_period,
                 bad_period == 0 ? "OK" : "FAIL");

        // ── 用例 7：en = 0 时 pwm 必须立即变低 ──────────────────────────────
        duty = PMAX / 2;                    // 先让它有一半时间在高
        repeat (PERIOD) @(posedge clk);
        en = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        check(pwm === 1'b0, "en=0 后 pwm 应立即为低");
        $display("  [7] en=0 后 pwm=0 .................... %s", pwm === 1'b0 ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  pwm_gen 全部用例通过");
        else
            $display("FAIL  pwm_gen 有 %0d 项未通过", errors);

        $finish;
    end

    // 超时保护：万一卡死，别让仿真无限跑
    initial begin
        #500000;
        $display("FAIL  仿真超时");
        $finish;
    end

endmodule
