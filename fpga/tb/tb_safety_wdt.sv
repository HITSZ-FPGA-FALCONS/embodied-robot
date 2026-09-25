// ============================================================================
//  tb_safety_wdt —— safety_wdt 的 testbench
// ----------------------------------------------------------------------------
//  验证目标：
//
//    1. 复位后 fault=0、pwm_en=1
//    2. 持续喂狗 → 永远不 fault
//    3. 停止喂狗 → 恰好 timeout 后 fault=1、pwm_en=0
//    4. ⭐ fault 之后**继续喂狗也不恢复**（本模块最重要的特性）
//    5. fault 只能靠 rst_n 清除
//    6. 边界：刚好在阈值前一脚踢 → 不 fault
//    7. timeout_ms 改阈值即时生效
//    8. timeout_ms=0 → 立即触发（fail-safe，不是"永不触发"）
//
//  运行：
//    iverilog -g2012 -o sim.out fpga/tb/tb_safety_wdt.sv fpga/rtl/safety_wdt.v
//    vvp sim.out
//
//  ────────────────────────────────────────────────────────────────────────────
//  仿真参数取巧
//  ────────────────────────────────────────────────────────────────────────────
//  真实是 CLK_HZ=50_000_000（每 ms 五万拍），仿真里跑 200 ms 要一千万拍。
//  这里取 **CLK_HZ=1000**，于是 CYC_PER_MS = 1 —— **1 拍就代表 1 ms**。
//  模块逻辑与频率无关，所以这样测的是同一件事，只是快一万倍。
//
//  ⚠️ 脉冲一律在 **negedge** 驱动，不在 posedge 上驱动。
//     09-20 踩过：`x=1; @(posedge clk); x=0;` 的清零与 DUT 采样同刻竞争，
//     谁先执行由仿真器定，实测 DUT 一次都没看到脉冲。
// ============================================================================

`timescale 1ns / 1ps

module tb_safety_wdt;

    localparam int CLK_HZ = 1000;       // CYC_PER_MS = 1
    localparam int RS_LV  = 0;

    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;
    logic        kick  = 1'b0;
    logic [15:0] timeout_ms = 16'd10;
    logic        fault;
    logic        pwm_en;

    safety_wdt #(
        .CLK_HZ (CLK_HZ),
        .RS_LV  (RS_LV)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .kick       (kick),
        .timeout_ms (timeout_ms),
        .fault      (fault),
        .pwm_en     (pwm_en)
    );

    always #10 clk = ~clk;

    int errors = 0;

    task automatic check(input bit cond, input string msg);
        if (cond !== 1'b1) begin
            $display("  FAIL: %s", msg);
            errors++;
        end
    endtask

    // 在 negedge 驱动单周期 kick（见文件头说明）
    task automatic pulse_kick();
        @(negedge clk);
        kick = 1'b1;
        @(negedge clk);
        kick = 1'b0;
    endtask

    task automatic wait_pos(input int n);
        repeat (n) @(posedge clk);
    endtask

    // 从当前时刻起，数到 fault 拉高用了多少拍；超过 limit 就放弃
    task automatic cycles_to_fault(input int limit, output int n);
        n = 0;
        while (!fault && n < limit) begin
            @(posedge clk);
            n++;
        end
    endtask

    int n;

    initial begin
        $dumpfile("wave_wdt.vcd");
        $dumpvars(0, tb_safety_wdt);

        $display("=== safety_wdt 测试开始 ===");
        $display("  CLK_HZ=%0d  →  CYC_PER_MS=%0d  →  1 拍 = 1 ms", CLK_HZ, CLK_HZ/1000);
        $display("");

        // ── 用例 1：复位 ────────────────────────────────────────────────────
        rst_n = 1'b0;
        wait_pos(4);
        #1;
        check(fault === 1'b0, "复位后 fault 应为 0");
        check(pwm_en === 1'b1, "复位后 pwm_en 应为 1（没故障就不该拦 PWM）");
        $display("  [1] 复位后 fault=0 pwm_en=1 ........... %s",
                 (fault === 1'b0 && pwm_en === 1'b1) ? "OK" : "FAIL");
        rst_n = 1'b1;
        wait_pos(2);

        // ── 用例 2：持续喂狗 → 永远不 fault ────────────────────────────────
        //     跑 100 拍，每 5 拍踢一次，阈值是 10 —— 踢得比阈值勤，就不该报故障。
        for (int i = 0; i < 20; i++) begin
            pulse_kick();
            wait_pos(5);
        end
        check(fault === 1'b0, "持续喂狗时不应 fault");
        $display("  [2] 持续喂狗 100 拍 fault=%0d (期望 0) .. %s", fault, fault == 0 ? "OK" : "FAIL");

        // ── 用例 3：停止喂狗 → 恰好 timeout 后 fault ───────────────────────
        //     先把计数器喂到 0，再数拍。
        timeout_ms = 16'd10;
        pulse_kick();
        cycles_to_fault(50, n);
        check(n >= 10 && n <= 12, $sformatf("超时应在约 10 拍发生，实测 %0d 拍", n));
        check(fault === 1'b1, "停止喂狗后 fault 应为 1");
        check(pwm_en === 1'b0, "fault 后 pwm_en 应为 0");
        $display("  [3] 停止喂狗 %0d 拍后 fault=%0d pwm_en=%0d .. %s",
                 n, fault, pwm_en, (n >= 10 && n <= 12 && fault == 1'b1 && pwm_en === 1'b0) ? "OK" : "FAIL");

        // ── 用例 4：⭐ fault 之后继续喂狗也不恢复 ──────────────────────────
        //     这是本模块最重要的特性。自动恢复的看门狗会让"持续故障"
        //     变成"周期性抽搐"——车每 200 ms 动一下，比停住更危险。
        for (int i = 0; i < 10; i++) begin
            pulse_kick();
            wait_pos(3);
        end
        check(fault === 1'b1, "fault 后即使持续喂狗也必须保持为 1");
        check(pwm_en === 1'b0, "fault 后 pwm_en 必须保持 0");
        $display("  [4] fault 后喂狗 10 次 fault=%0d (期望 1)  %s", fault, fault == 1 ? "OK" : "FAIL");

        // ── 用例 5：只有 rst_n 能清除 ──────────────────────────────────────
        rst_n = 1'b0;
        wait_pos(3);
        #1;
        check(fault === 1'b0, "复位应能清除 fault");
        check(pwm_en === 1'b1, "复位后 pwm_en 应恢复为 1");
        $display("  [5] 复位清除 fault=%0d pwm_en=%0d ..... %s",
                 fault, pwm_en, (fault === 1'b0 && pwm_en === 1'b1) ? "OK" : "FAIL");
        rst_n = 1'b1;
        wait_pos(2);

        // ── 用例 6：边界 —— 刚好在阈值前踢一脚 ─────────────────────────────
        //     阈值 10，喂完等 9 拍再喂 → 不该 fault；然后再不管它 → 该 fault。
        timeout_ms = 16'd10;
        pulse_kick();
        wait_pos(9);
        check(fault === 1'b0, "第 9 拍（阈值前）不应 fault");
        pulse_kick();                    // 及时喂，救回来
        wait_pos(9);
        check(fault === 1'b0, "踢一脚后计数应重头开始，第 9 拍仍不应 fault");
        $display("  [6] 阈值前喂狗不误报 fault=%0d ........ %s", fault, fault == 0 ? "OK" : "FAIL");
        cycles_to_fault(30, n);
        check(fault === 1'b1, "此后不再喂应 fault");
        $display("  [6b] 随后停止喂 %0d 拍后 fault=%0d ....... %s", n, fault, fault == 1 ? "OK" : "FAIL");

        // ── 用例 7：改阈值即时生效 ─────────────────────────────────────────
        rst_n = 1'b0; wait_pos(3); rst_n = 1'b1; wait_pos(2);
        timeout_ms = 16'd5;              // 阈值改成 5
        pulse_kick();
        cycles_to_fault(30, n);
        check(n >= 5 && n <= 7, $sformatf("阈值 5 时应在约 5 拍超时，实测 %0d", n));
        $display("  [7] 阈值改 5 后 %0d 拍超时 (期望约 5) .. %s",
                 n, (n >= 5 && n <= 7) ? "OK" : "FAIL");

        // ── 用例 8：timeout_ms=0 → 立即触发（fail-safe）─────────────────────
        //     阈值配错时必须"立刻停车"，不能"永不触发"。
        //     一个配错了就静默失效的看门狗，等于没有看门狗。
        rst_n = 1'b0; wait_pos(3); rst_n = 1'b1; wait_pos(2);
        timeout_ms = 16'd0;
        cycles_to_fault(10, n);
        check(fault === 1'b1, "timeout_ms=0 时应立即 fault（而非永不触发）");
        check(n <= 2, $sformatf("timeout_ms=0 应立即故障，实测 %0d 拍", n));
        $display("  [8] timeout_ms=0 立即 fault=%0d (%0d 拍) . %s",
                 fault, n, (fault == 1'b1 && n <= 2) ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  safety_wdt 全部用例通过");
        else
            $display("FAIL  safety_wdt 有 %0d 项未通过", errors);

        $finish;
    end

    initial begin
        #500000;
        errors++;
        $display("");
        $display("FAIL  safety_wdt 仿真超时（有用例卡死，未跑完）");
        $finish;
    end

endmodule
