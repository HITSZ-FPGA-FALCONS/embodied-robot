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
//    7. en = 0 时 pwm 立即变低，且计数器被清零
//    8. dir 直通到 dir_o
//    9. PERIOD 是 2 的幂时的回绕（PERIOD=8 的另一路实例）
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ 写"负向用例"的一条通用教训
//  ────────────────────────────────────────────────────────────────────────────
//  一个用例只有在**坏设计会挂掉**的前提下才有价值。
//
//  写完之后要对自己问一句：**"如果我故意把这个功能删掉，这条还过吗？"**
//  如果还过，那它测的不是它以为的那个东西。本文件里 [1] 和 [6] 都踩过这个坑，
//  注释里写明了踩坑的过程——那不是废话，是防止下一个人再踩一遍。
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

    // DUT 内部计数器的位宽，只用于下面的**白盒**检查（直接看 u_dut.cnt）。
    // 白盒检查会依赖内部的信号名，DUT 里改名这份 TB 就会编译不过——
    // 这是故意的：宁可报错，也不要静默地不再检查。
    localparam CNT_W = $clog2(PERIOD);

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

    // ── 第二路实例：PERIOD 为 2 的幂（用例 9 用）────────────────────────────
    //
    //  为什么要多这一路？
    //  主实例的 PERIOD=10 不是 2 的幂，计数器只用到 0~9，
    //  而 4 位寄存器能表示 0~15 —— **用不满**。
    //  用不满时，即使回绕条件写错一点，cnt 也未必溢出错位，问题被掩盖。
    //
    //  PERIOD=8 是 2 的幂：3 位计数器刚好走满 0~7，
    //  终值 7 正好是"全 1"。这是 $clog2 和终值判断最容易出错的地方。
    localparam P2_HZ     = 125;                 // CLK_HZ / P2_HZ = 1000/125 = 8
    localparam P2_PERIOD = CLK_HZ / P2_HZ;

    reg  [DUTY_W-1:0] p2_duty = {DUTY_W{1'b0}};
    reg               p2_en   = 1'b0;
    wire              p2_pwm;

    pwm_gen #(
        .CLK_HZ (CLK_HZ),
        .PWM_HZ (P2_HZ),
        .DUTY_W (DUTY_W)
    ) u_p2 (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (p2_en),
        .duty  (p2_duty),
        .dir   (1'b0),
        .pwm   (p2_pwm),
        .dir_o ()
    );

    always #5 clk = ~clk;                   // 周期 10 ns

    integer errors = 0;

    // ── 检查任务 ────────────────────────────────────────────────────────────
    //
    //  ⚠️ 用 `cond !== 1'b1` 而不是 `!cond`：
    //     `!x` 的结果是 x，而 `if (x)` 会被当成假 → 不报 FAIL。
    //     也就是说写成 !cond 时，一个"结果是未知态 x"的检查会被**静默当成通过**，
    //     而 x 恰恰是"没驱动""时序没收敛"这类真问题的表现。
    //     `!==` 是四值比较：只有 cond 严格等于 1 才算过。
    task check;
        input        cond;
        input string msg;
        begin
            if (cond !== 1'b1) begin
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

    // 第二路实例的测量任务（同样的思路，只是换一组信号和周期）
    integer p2_hi;
    task measure_p2;
        input [DUTY_W-1:0] d;
        integer k;
        begin
            p2_duty = d;
            repeat (P2_PERIOD) @(posedge clk);
            p2_hi = 0;
            for (k = 0; k < 10 * P2_PERIOD; k = k + 1) begin
                @(posedge clk);
                if (p2_pwm) p2_hi = p2_hi + 1;
            end
        end
    endtask

    // ── 周期监视器：检查相邻两次上升沿之间是否恰好隔 PERIOD 拍 ───────────────
    integer cyc        = 0;
    integer prev_rise  = -1;
    integer bad_period = 0;
    integer rises      = 0;             // 窗口内看到几次上升沿
    reg     pwm_d      = 1'b0;
    reg     mon_en     = 1'b0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (mon_en && pwm && !pwm_d) begin
            rises = rises + 1;          // 必须数：一次都没看到 ≠ 周期正确
            if (prev_rise >= 0 && (cyc - prev_rise) != PERIOD) begin
                bad_period = bad_period + 1;
                $display("    PWM 周期异常: 第 %0d 拍 → 第 %0d 拍 = %0d，应为 %0d",
                         prev_rise, cyc, cyc - prev_rise, PERIOD);
            end
            prev_rise = cyc;
        end
        pwm_d = pwm;
    end

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_pwm_gen);

        $display("=== pwm_gen 测试开始 ===");
        $display("  CLK_HZ=%0d  PWM_HZ=%0d  →  PERIOD=%0d  DUTY_W=%0d",
                 CLK_HZ, PWM_HZ, PERIOD, DUTY_W);
        $display("");

        // ── 用例 1：复位期间 pwm 必须为低 ───────────────────────────────────
        //
        //  ⚠️ 这个用例第一版是错的，值得说清楚：
        //
        //     第一版同时拉了 rst_n=0 和 en=0。看起来在测复位，其实没有——
        //     DUT 里 `else if (!en)` 分支自己就会把 pwm 和 cnt 清零，
        //     所以**把整个复位分支删掉，这条照样通过**。
        //
        //     条件必须这样设：
        //       en = 1    → 排除"en 分支帮忙拉低"
        //       duty ≠ 0  → 排除"输出本来就该是低"
        //     两个帮手都排除掉，pwm 还停在低，才真的说明是复位在起作用。
        rst_n = 1'b0; en = 1'b1; duty = PMAX / 2;
        repeat (3) @(posedge clk);
        #1;
        check(pwm === 1'b0, "复位期间 pwm 应为低（已排除 en=0 和 duty=0 两种干扰）");
        $display("  [1] 复位期间 pwm=0 ................... %s", pwm === 1'b0 ? "OK" : "FAIL");

        // 复位期间计数器也必须被清零
        check(u_dut.cnt === {CNT_W{1'b0}}, "复位期间计数器 cnt 应为 0");
        $display("  [1b] 复位期间 cnt=0 .................. %s",
                 u_dut.cnt === {CNT_W{1'b0}} ? "OK" : "FAIL");

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
        //     方法：连续观察多个周期，看相邻上升沿间隔是否恒为 PERIOD。
        //     用例 2~5 只能证明"占空比对的"，不能证明"频率对的"——
        //     一个慢 10 倍的 PWM 也能通过占空比检查。所以这一条必须单独做。
        //
        //  ⚠️ 窗口长度是这一条的命门，第一版就栽在这里：
        //
        //     第一版只观察 PERIOD*10 = 100 拍。一个"慢 10 倍但占空比不变"的
        //     坏设计（周期 100 拍、每 100 拍里高 10 拍），在这 100 拍窗口里
        //     只会出现 **1 次**上升沿。而第 1 次上升沿只用来记起点、
        //     不参与间隔比较 → bad_period 恒为 0 → **假通过**。
        //
        //     而且这个假通过是必然的，不是碰运气：
        //     窗口长度正好等于一个周期时，里面必然恰好只有一次上升沿。
        //
        //     两个修正缺一不可：
        //       ① 窗口拉长到 PERIOD*50，让坏设计也露头（周期 100 拍 → 5 次上升沿）
        //       ② 另外数 rises，并要求次数下限 —— "一次都没看到"不等于"周期正确"
        duty = 4'd1;                        // 1/PERIOD 占空比，每周期有一个干净的上升沿
        repeat (PERIOD * 2) @(posedge clk);
        prev_rise = -1; bad_period = 0; rises = 0; mon_en = 1'b1;
        repeat (PERIOD * 50) @(posedge clk);
        mon_en = 1'b0;
        check(rises >= 5 && bad_period == 0,
              $sformatf("应看到 >=5 次上升沿且间隔恒为 %0d 拍；实测 %0d 次上升沿、%0d 次间隔异常",
                        PERIOD, rises, bad_period));
        $display("  [6] 上升沿 %0d 次 / 间隔异常 %0d 次 (期望 >=5 / 0) %s",
                 rises, bad_period, (rises >= 5 && bad_period == 0) ? "OK" : "FAIL");

        // ── 用例 7：en = 0 时 pwm 必须立即变低，且计数器清零 ────────────────
        //
        //  ⚠️ 必须先确认"变低之前它真的是高的"。
        //     否则一个**永远输出低**的坏设计也会通过这一条——
        //     它连 [7] 都过不了才算奇怪。
        duty = PMAX / 2;
        repeat (PERIOD) @(posedge clk);
        while (!pwm) @(posedge clk);        // 等到它确实是高（一直等不到会被超时抓到）
        #1;
        check(pwm === 1'b1, "en=1 且 duty=50% 时应当能等到 pwm 为高");
        $display("  [7a] en=1 时能等到 pwm=1 ............. %s", pwm === 1'b1 ? "OK" : "FAIL");

        en = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        check(pwm === 1'b0, "en=0 后 pwm 应立即为低");
        $display("  [7b] en=0 后 pwm 立即变低 ............ %s", pwm === 1'b0 ? "OK" : "FAIL");

        // 计数器的清零只能白盒看——从引脚上根本观察不到：
        // PWM 是周期信号，任意 PERIOD 拍窗口里高低拍数都一样，
        // 所以"计数器有没有归零"在波形上被相位掩盖了。
        check(u_dut.cnt === {CNT_W{1'b0}}, "en=0 期间计数器 cnt 应被清零");
        $display("  [7c] en=0 期间 cnt=0 ................. %s",
                 u_dut.cnt === {CNT_W{1'b0}} ? "OK" : "FAIL");

        // 重新使能后应能正常工作
        en = 1'b1;
        measure(PMAX / 2, 5);
        check(hi == 5 * PERIOD / 2,
              $sformatf("重新使能后 duty=PERIOD/2 应高 %0d 拍，实测 %0d", 5 * PERIOD / 2, hi));
        $display("  [7d] 重新使能后占空比正常 %0d 拍 ..... %s",
                 hi, hi == 5 * PERIOD / 2 ? "OK" : "FAIL");

        // ── 用例 8：dir 直通到 dir_o ────────────────────────────────────────
        //     dir_o 是冻结接口的一部分（见接口表 §3.1）。不验的话，
        //     一个 dir_o 悬空或接错的设计能通过上面全部用例。
        dir = 1'b1;
        #1;
        check(dir_o === 1'b1, "dir=1 时 dir_o 应为 1");
        $display("  [8] dir 直通到 dir_o (dir=1) ......... %s", dir_o === 1'b1 ? "OK" : "FAIL");
        dir = 1'b0;
        #1;
        check(dir_o === 1'b0, "dir=0 时 dir_o 应为 0");
        $display("  [8b] dir 直通到 dir_o (dir=0) ........ %s", dir_o === 1'b0 ? "OK" : "FAIL");

        // ── 用例 9：PERIOD 为 2 的幂时的回绕（第二路实例，PERIOD=8）──────────
        //     验证的仍然是"占空比 = duty/PERIOD"，但这次计数器的位宽刚好用满，
        //     终值 PERIOD-1 = 7 是全 1。$clog2 / 终值判断写错的话，
        //     主实例（PERIOD=10，位宽用不满）未必暴露，这里会暴露。
        p2_en = 1'b1;
        repeat (2) @(posedge clk);

        measure_p2(4'd0);
        check(p2_hi == 0, $sformatf("PERIOD=8 duty=0 应恒低，实测高了 %0d 拍", p2_hi));
        $display("  [9a] PERIOD=8 duty=0      高 %0d 拍 (期望 0) ..... %s",
                 p2_hi, p2_hi == 0 ? "OK" : "FAIL");

        measure_p2(4'd4);                   // 8 的一半
        check(p2_hi == 10 * P2_PERIOD / 2,
              $sformatf("PERIOD=8 duty=4 应高 %0d 拍，实测 %0d", 10 * P2_PERIOD / 2, p2_hi));
        $display("  [9b] PERIOD=8 duty=4      高 %0d 拍 (期望 %0d) ... %s",
                 p2_hi, 10 * P2_PERIOD / 2, p2_hi == 10 * P2_PERIOD / 2 ? "OK" : "FAIL");

        measure_p2(4'd8);                   // 满量程，正好等于 PERIOD
        check(p2_hi == 10 * P2_PERIOD,
              $sformatf("PERIOD=8 duty=PERIOD 应恒高 %0d 拍，实测 %0d", 10 * P2_PERIOD, p2_hi));
        $display("  [9c] PERIOD=8 duty=PERIOD 高 %0d 拍 (期望 %0d) %s",
                 p2_hi, 10 * P2_PERIOD, p2_hi == 10 * P2_PERIOD ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  pwm_gen 全部用例通过");
        else
            $display("FAIL  pwm_gen 有 %0d 项未通过", errors);

        $finish;
    end

    // 超时保护：万一卡死（比如用例 7 的 while 一直等不到高电平），
    // 别让仿真无限跑。也要走汇总格式，否则打印出来的"FAIL"和最后的
    // "PASS/FAIL"总结对不上，看日志的人会以为仿真正常结束了。
    initial begin
        #500000;
        errors = errors + 1;
        $display("");
        $display("FAIL  pwm_gen 仿真超时（有用例卡死，未跑完）");
        $finish;
    end

endmodule
