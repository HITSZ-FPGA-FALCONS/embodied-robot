// ============================================================================
//  tb_encoder_counter —— encoder_counter 的 testbench
// ----------------------------------------------------------------------------
//  验证目标（每一条都要有对应的检查，不能只看波形）：
//
//    1. 复位后 pos / vel 为 0
//    2. 正转 N 步 → pos == +N（A 领先 B）
//    3. 反转 M 步 → pos == N-M
//    4. 四倍频：一个完整电气周期（4 次跳变）= 4 格，不是 1 格
//    5. clr 单周期脉冲 → pos 清零
//    6. 抖动抑制：只有 A 在抖、B 不动 → 净计数为 0
//    7. 非法跳变：A 和 B 同拍翻转 → 不计数
//    8. 测速：tick 后的 vel == 该周期内的位置增量（含负方向）
//    9. clr 之后速度基准归零（不会算出 0-旧位置 的巨大负值）
//
//  运行：
//    iverilog -g2012 -o sim.out fpga/tb/tb_encoder_counter.sv fpga/rtl/encoder_counter.v
//    vvp sim.out
//
//  ────────────────────────────────────────────────────────────────────────────
//  这个 TB 的核心约定：一个"步"= 一次正交状态跳变
//  ────────────────────────────────────────────────────────────────────────────
//  编码器的 A/B 不是自由变化的两个信号，它们只能按固定的循环走：
//
//      正转：10 → 11 → 01 → 00 → 10 → ...
//      反转：10 → 00 → 01 → 11 → 10 → ...
//
//  所以 TB 不去"想怎么给激励"，只维护一个下标在 FWD 数组上前后移动。
//  **反转就是下标往回走**，不需要另写一套波形——两套波形容易写错一个，
//  而错的那套往往正好把方向写反，结果测试通过了、车却倒着走。
//
//  ⚠️ 每个状态要**等够拍数**再改下一次。信号从引脚进到 pos 要经过：
//      同步器第 1 拍 → 同步器第 2 拍 → 译码比较那一拍
//  共 3 拍。SETTLE 取 4 留一拍余量。
// ============================================================================

`timescale 1ns / 1ps

module tb_encoder_counter;

    localparam int POS_W  = 32;
    localparam int VEL_W  = 16;
    localparam int RS_LV  = 0;

    // 改一次引脚后等几拍再改下一次（见文件头说明）
    localparam int SETTLE = 4;

    // 正交状态循环：正转顺序（A 领先 B）
    // 反转 = 下标往回走
    //
    // ⚠️ 这里用函数而不是 `localparam ... [0:3] = '{...}`：
    //    iverilog v12 不支持用赋值模式初始化非压缩数组的 localparam
    //    （报 "localparam must have a value"）。函数写法两套版本都能编译。
    function automatic logic [1:0] seq_at(input int i);
        case (i)
            0:       seq_at = 2'b10;
            1:       seq_at = 2'b11;
            2:       seq_at = 2'b01;
            default: seq_at = 2'b00;
        endcase
    endfunction

    logic              clk   = 1'b0;
    logic              rst_n = 1'b0;
    logic              enc_a = 1'b0;
    logic              enc_b = 1'b0;
    logic              clr   = 1'b0;
    logic              tick  = 1'b0;
    logic signed [POS_W-1:0] pos;
    logic signed [VEL_W-1:0] vel;

    encoder_counter #(
        .POS_W (POS_W),
        .VEL_W (VEL_W),
        .RS_LV (RS_LV)
    ) u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .enc_a (enc_a),
        .enc_b (enc_b),
        .clr   (clr),
        .tick  (tick),
        .pos   (pos),
        .vel   (vel)
    );

    always #10 clk = ~clk;              // 50 MHz

    int errors = 0;
    int seq_idx = 0;

    // ── 检查任务 ────────────────────────────────────────────────────────────
    // 用 !== 做四值比较：结果是 x（没驱动/没收敛）时必须报 FAIL，
    // 不能被静默当成通过。
    task automatic check(input bit cond, input string msg);
        if (cond !== 1'b1) begin
            $display("  FAIL: %s", msg);
            errors++;
        end
    endtask

    // ── 把 A/B 置成指定状态并等稳定 ─────────────────────────────────────────
    task automatic apply(input logic [1:0] ab);
        {enc_a, enc_b} = ab;
        repeat (SETTLE) @(posedge clk);
    endtask

    // ── 走 n 步；n 为正是正转，为负是反转 ──────────────────────────────────
    task automatic step(input int n);
        int i;
        for (i = 0; i < (n < 0 ? -n : n); i++) begin
            seq_idx = (n > 0) ? (seq_idx + 1) % 4 : (seq_idx - 1 + 4) % 4;
            apply(seq_at(seq_idx));
        end
    endtask

    // ── 单周期脉冲 ──────────────────────────────────────────────────────────
    //
    // ⚠️ 必须驱动在**时钟低电平**期间，绝不能驱动在 posedge 上。
    //
    //     原来的写法：
    //         clr = 1'b1;  @(posedge clk);  clr = 1'b0;
    //     看着是"高一个周期"，但 `clr = 1'b0` 与 DUT 在同一个 posedge 读 `clr`
    //     是**同一时刻的两个进程**，谁先谁后由仿真器定。
    //     清零若先执行，DUT 根本看不到这一拍脉冲。
    //
    //     现象极具迷惑性：波形上脉冲明明在，DUT 却像没收到。
    //     实测（iverilog v12）在本 TB 里就是 clr **一次都没变成 1**。
    //
    //     改在 negedge 驱动：置 1 在 posedge 之前半拍，清 0 在 posedge 之后半拍，
    //     两边都远离采样沿，race 消失。
    task automatic pulse_clr();
        @(negedge clk);
        clr = 1'b1;
        @(negedge clk);
        clr = 1'b0;
    endtask

    task automatic pulse_tick();
        @(negedge clk);
        tick = 1'b1;
        @(negedge clk);
        tick = 1'b0;
    endtask

    // ── 把位置基准归零：走到 SEQ[0]、clr、确认 pos==0 ───────────────────────
    // 复位后同步器被清成 00，而编码器实际可能停在别的状态，
    // 会产生一次 ±1 的假计数（见 RTL 注释）。所以每个测试段开始时
    // 都先走这一步，把基准对齐，免得每个用例都在跟这个偏移较劲。
    task automatic align_zero();
        seq_idx = 0;
        apply(seq_at(0));
        pulse_clr();
    endtask

    initial begin
        $dumpfile("wave_encoder.vcd");
        $dumpvars(0, tb_encoder_counter);

        $display("=== encoder_counter 测试开始 ===");
        $display("  POS_W=%0d  VEL_W=%0d  RS_LV=%0d  SETTLE=%0d 拍", POS_W, VEL_W, RS_LV, SETTLE);
        $display("");

        // ── 用例 1：复位 ────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1;
        check(pos === '0, $sformatf("复位后 pos 应为 0，实测 %0d", pos));
        check(vel === '0, $sformatf("复位后 vel 应为 0，实测 %0d", vel));
        $display("  [1] 复位后 pos=0 vel=0 ............... %s",
                 (pos === '0 && vel === '0) ? "OK" : "FAIL");

        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ── 用例 2：正转 8 步 → pos == 8 ────────────────────────────────────
        align_zero();
        step(8);
        check(pos == 32'sd8, $sformatf("正转 8 步后 pos 应为 8，实测 %0d", pos));
        $display("  [2] 正转 8 步   pos=%0d (期望 8) ...... %s", pos, pos == 8 ? "OK" : "FAIL");

        // ── 用例 3：反转 3 步 → pos == 5 ────────────────────────────────────
        step(-3);
        check(pos == 32'sd5, $sformatf("再反转 3 步后 pos 应为 5，实测 %0d", pos));
        $display("  [3] 反转 3 步   pos=%0d (期望 5) ...... %s", pos, pos == 5 ? "OK" : "FAIL");

        // ── 用例 4：四倍频 —— 一个完整电气周期 = 4 格 ───────────────────────
        //     这条专门防"以为一圈算一格"的误解。线数 500 的编码器，
        //     四倍频后每圈是 2000 格，不是 500。
        align_zero();
        step(4);                        // 正好走完 10→11→01→00→10
        check(pos == 32'sd4, $sformatf("一个完整电气周期应为 4 格，实测 %0d", pos));
        $display("  [4] 一个电气周期 pos=%0d (期望 4) .... %s", pos, pos == 4 ? "OK" : "FAIL");

        // ── 用例 5：clr 清零 ────────────────────────────────────────────────
        step(5);
        pulse_clr();
        check(pos == 32'sd0, $sformatf("clr 后 pos 应为 0，实测 %0d", pos));
        $display("  [5] clr 后 pos=%0d (期望 0) .......... %s", pos, pos == 0 ? "OK" : "FAIL");

        // ── 用例 6：抖动抑制 —— 只有 A 在抖、B 不动 ─────────────────────────
        //     B 固定为 0，A 来回翻 10 次：00→10→00→10...
        //     每次 00→10 是 +1，每次 10→00 是 -1，**成对抵消**。
        //     这正是机械抖动/接触不良在真实系统里的样子。
        align_zero();
        enc_b = 1'b0;
        for (int i = 0; i < 10; i++) begin
            enc_a = ~enc_a;
            repeat (SETTLE) @(posedge clk);
        end
        check(pos == 32'sd0, $sformatf("A 抖动 10 次净计数应为 0，实测 %0d", pos));
        $display("  [6] A 抖动 10 次 pos=%0d (期望 0) ..... %s", pos, pos == 0 ? "OK" : "FAIL");

        // ── 用例 7：非法跳变 —— A 和 B 同拍翻转 ─────────────────────────────
        //     真实的正交信号不可能两相同时变。这种输入只可能来自
        //     毛刺或接线错误，**必须不计数**——否则一个毛刺就是一次假计数。
        align_zero();                   // 停在 10 状态，pos=0
        step(2);                        // 走到 01，pos=2
        pulse_clr();                    // pos 归零；编码器此时停在 01
        {enc_a, enc_b} = 2'b10;         // 01 → 10：两相同时变，非法
        repeat (SETTLE) @(posedge clk);
        check(pos == 32'sd0, $sformatf("非法跳变 01→10 不应计数，实测 pos=%0d", pos));
        $display("  [7] 非法跳变 01→10  pos=%0d (期望 0) . %s", pos, pos == 0 ? "OK" : "FAIL");
        seq_idx = 0;

        // ── 用例 8：测速（正方向）──────────────────────────────────────────
        align_zero();                   // clr 会把速度基准也归零
        step(6);
        pulse_tick();
        check(vel == 16'sd6, $sformatf("正转 6 步后 vel 应为 6，实测 %0d", vel));
        $display("  [8] 正转 6 步后 vel=%0d (期望 6) ..... %s", vel, vel == 6 ? "OK" : "FAIL");

        // ── 用例 9：测速（负方向）──────────────────────────────────────────
        //     vel 必须能表示负数。这是最容易漏的一条：
        //     如果 vel 被写成无符号，反转时会变成一个巨大的正数。
        step(-4);
        pulse_tick();
        check(vel == -16'sd4, $sformatf("反转 4 步后 vel 应为 -4，实测 %0d", vel));
        $display("  [9] 反转 4 步后 vel=%0d (期望 -4) .... %s", vel, vel == -4 ? "OK" : "FAIL");

        // ── 用例 10：clr 之后速度基准必须归零 ──────────────────────────────
        //     clr 只清 pos 不清基准的话，下一个 tick 会算出 (0 - 旧位置)，
        //     是个巨大的负值，看起来像"车倒着飞出去了"。
        align_zero();
        step(20);
        pulse_clr();                    // pos 归零，基准也应归零
        pulse_tick();
        check(vel == 16'sd0, $sformatf("clr 后第一个 tick 的 vel 应为 0，实测 %0d", vel));
        $display("  [10] clr 后首个 tick vel=%0d (期望 0)  %s", vel, vel == 0 ? "OK" : "FAIL");

        // ── 用例 11：长时间累计不丢步、不截断 ──────────────────────────────
        align_zero();
        step(200);
        check(pos == 32'sd200, $sformatf("正转 200 步后 pos 应为 200，实测 %0d", pos));
        $display("  [11] 正转 200 步 pos=%0d (期望 200) .. %s", pos, pos == 200 ? "OK" : "FAIL");
        step(-200);
        check(pos == 32'sd0, $sformatf("再反转 200 步应回到 0，实测 %0d", pos));
        $display("  [11b] 反转 200 步回到 pos=%0d (期望 0) %s", pos, pos == 0 ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  encoder_counter 全部用例通过");
        else
            $display("FAIL  encoder_counter 有 %0d 项未通过", errors);

        $finish;
    end

    // 超时保护：万一卡死，别让仿真无限跑，也别打印出像"正常结束"的输出
    initial begin
        #2000000;
        errors++;
        $display("");
        $display("FAIL  encoder_counter 仿真超时（有用例卡死，未跑完）");
        $finish;
    end

endmodule
