// ============================================================================
//  tb_clk_div —— clk_div 的 testbench
// ----------------------------------------------------------------------------
//  验证目标（每一条都要有对应的检查，不能只看波形）：
//
//    1. 复位后 tick 为低、计数器归零
//    2. tick 每 DIV 个周期出现一次
//    3. tick 的宽度恰好是 1 个时钟周期（不是 2 个、不是半个）
//    4. 复位能中途打断计数（异步复位）
//
//  运行： sim.bat fpga\tb\tb_clk_div.v fpga\rtl\clk_div.v
// ============================================================================

`timescale 1ns / 1ps

module tb_clk_div;

    // 测试用小分频比，跑得快。DIV=10 → 每 10 个周期一个 tick
    localparam DIV = 10;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    wire tick;

    clk_div #(.DIV(DIV)) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick)
    );

    // 50 MHz：周期 20 ns
    always #10 clk = ~clk;

    // ── 监测：记录每次 tick 发生在第几个时钟周期，并检查相邻间隔 ────────────
    //
    //  ⚠️ 这里有个 Verilog 核心概念，务必理解：
    //
    //     在同一个时钟沿，TB 的 always 块读到的 tick 是【上一周期】的值。
    //     因为 DUT 里用非阻塞赋值（<=）写 tick，它在整个时刻的最后才更新；
    //     而 TB 的 always 块在时刻开始时就读了。
    //
    //     这不是 bug，硬件上也是这样：同一个时钟沿，后级触发器采到的是
    //     前级触发器【更新前】的值。
    //
    //  所以本 TB 不数"某窗口内几次 tick"（会被这个偏移影响），
    //  而是测【相邻两次 tick 之间隔了多少个周期】——这才是规格本身。

    integer cyc           = 0;     // 周期计数
    integer tick_count    = 0;     // tick 总次数
    integer prev_cyc      = -1;    // 上一次 tick 所在的周期号
    integer bad_intervals = 0;     // 间隔不等于 DIV 的次数
    integer errors        = 0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (rst_n && tick) begin
            if (prev_cyc >= 0 && (cyc - prev_cyc) != DIV) begin
                bad_intervals = bad_intervals + 1;
                $display("    间隔异常: 第 %0d 周期到第 %0d 周期 = %0d，应为 %0d",
                         prev_cyc, cyc, cyc - prev_cyc, DIV);
            end
            prev_cyc   = cyc;
            tick_count = tick_count + 1;
        end
    end

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

    integer i;

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_clk_div);

        $display("=== clk_div 测试开始  DIV=%0d ===", DIV);

        // ── 用例 1：复位期间 tick 必须为低 ───────────────────────────────────
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;                                     // 让组合逻辑稳定
        check(tick === 1'b0, "复位期间 tick 应为低");
        $display("  [1] 复位期间 tick=0 .......... %s", tick === 1'b0 ? "OK" : "FAIL");

        // ── 释放复位 ────────────────────────────────────────────────────────
        rst_n = 1'b1;

        // ── 用例 2：跑足时间，应出现足够多次 tick ───────────────────────────
        tick_count = 0; bad_intervals = 0; prev_cyc = -1;
        for (i = 0; i < DIV * 5 + 2; i = i + 1) @(posedge clk);
        #1;
        check(tick_count >= 5,
              $sformatf("跑 %0d 周期应至少 5 次 tick，实际 %0d 次", DIV * 5 + 2, tick_count));
        $display("  [2] tick 出现次数 = %0d (期望 >=5) ...... %s",
                 tick_count, tick_count >= 5 ? "OK" : "FAIL");

        // ── 用例 3：相邻两次 tick 的间隔必须恒为 DIV ────────────────────────
        //     这才是"分频比正确"的真正判据，不受采样偏移影响
        check(bad_intervals == 0,
              $sformatf("相邻 tick 间隔应恒为 %0d 周期，有 %0d 次不符", DIV, bad_intervals));
        $display("  [3] 间隔异常次数 = %0d (期望 0) .......... %s",
                 bad_intervals, bad_intervals == 0 ? "OK" : "FAIL");

        // ── 用例 4：tick 宽度必须恰好 1 个周期 ──────────────────────────────
        //     方法：等到 tick 拉高，然后在下一个时钟沿检查它是否已拉低
        @(posedge clk);
        while (!tick) @(posedge clk);           // 等到 tick 为高
        @(posedge clk);
        #1;
        check(tick === 1'b0, "tick 宽度应为 1 个周期（下一拍必须已拉低）");
        $display("  [4] tick 宽度 = 1 周期 ........ %s", tick === 1'b0 ? "OK" : "FAIL");

        // ── 用例 5：运行中途复位，应能立即打断 ──────────────────────────────
        repeat (DIV / 2) @(posedge clk);        // 数到一半
        rst_n = 1'b0;                           // 异步复位
        repeat (2) @(posedge clk);
        #1;
        check(tick === 1'b0, "中途复位后 tick 应立即为低");
        $display("  [5] 中途复位 tick=0 .......... %s", tick === 1'b0 ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  clk_div 全部用例通过");
        else
            $display("FAIL  clk_div 有 %0d 项未通过", errors);

        $finish;
    end

    // 超时保护：万一卡死，别让仿真无限跑
    initial begin
        #100000;
        $display("FAIL  仿真超时");
        $finish;
    end

endmodule
