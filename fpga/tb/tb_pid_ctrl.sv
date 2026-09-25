// ============================================================================
//  tb_pid_ctrl —— pid_ctrl 的 testbench（**带被控对象模型**）
// ----------------------------------------------------------------------------
//  验证目标：
//
//    1. 复位后 duty=0、dir=0
//    2. en=0 时输出 0
//    3. ⭐ 阶跃响应能收敛（闭环真的能把速度拉到目标附近）
//    4. ⭐ 输出限幅：目标远超能力时 duty 饱和在 DUTY_MAX，不溢出
//    5. ⭐ 松开指令后能停下来（**验证 anti-windup**，见下）
//    6. 反向：目标为负 → dir=1 且 duty>0
//    7. en=0 清积分：重新使能的第一拍不应出现巨大输出
//    8. 稳态误差足够小（验证积分项在起作用）
//
//  ────────────────────────────────────────────────────────────────────────────
//  为什么要带对象模型
//  ────────────────────────────────────────────────────────────────────────────
//  只测"给定输入，输出等于某个数"是不够的 —— PID 的价值在于**闭环行为**：
//  会不会收敛、会不会过冲、松开指令后停不停得住。
//  所以 TB 里放了一个一阶电机模型，让 duty 真的去影响 actual：
//
//      指令速度 v_cmd = (duty / DUTY_MAX) × V_MAX × (dir ? -1 : +1)
//      实际速度 v     = v + (v_cmd − v) / TAU        ← 一阶惯性
//
//  这不是真实电机的精确模型，但**它足以把 PID 的典型错误暴露出来**：
//  积分饱和、方向反了、忘了限幅，在这个模型上都会表现为"停不下来"或"冲过头"。
// ============================================================================

`timescale 1ns / 1ps

module tb_pid_ctrl;

    localparam int DUTY_W     = 12;
    localparam int DUTY_MAX   = 2500;
    localparam int GAIN_SHIFT = 8;
    localparam int RS_LV      = 0;

    // ── 被控对象模型参数 ────────────────────────────────────────────────────
    localparam int V_MAX = 1000;    // duty 满时的速度（mm/s）
    localparam int TAU   = 3;       // 一阶惯性时间常数（控制周期数）
    localparam int CTRL_GAP = 5;    // 两个控制周期之间隔多少 clk

    logic                clk = 1'b0;
    logic                rst_n = 1'b0;
    logic                en = 1'b0;
    logic                tick = 1'b0;
    logic signed [15:0]  target = 16'sd0;
    logic signed [15:0]  actual = 16'sd0;
    logic [DUTY_W-1:0]   duty;
    logic                dir;

    pid_ctrl #(
        .DUTY_W     (DUTY_W),
        .DUTY_MAX   (DUTY_MAX),
        .GAIN_SHIFT (GAIN_SHIFT),
        .ACC_MAX    (200000),
        .RS_LV      (RS_LV)
    ) u_dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .en     (en),
        .tick   (tick),
        .target (target),
        .actual (actual),
        .duty   (duty),
        .dir    (dir)
    );

    always #10 clk = ~clk;

    int errors = 0;

    task automatic check(input bit cond, input string msg);
        if (cond !== 1'b1) begin
            $display("  FAIL: %s", msg);
            errors++;
        end
    endtask

    // 脉冲一律在 negedge 驱动（09-20 的教训）
    task automatic pulse_tick();
        @(negedge clk);
        tick = 1'b1;
        @(negedge clk);
        tick = 1'b0;
    endtask

    task automatic wait_pos(input int n);
        repeat (n) @(posedge clk);
    endtask

    // ── 被控对象：跑一个控制周期 ────────────────────────────────────────────
    int v_plant = 0;
    int v_cmd;

    task automatic control_step();
        pulse_tick();
        wait_pos(2);                    // 等 duty/dir 更新
        // 电机模型：把 duty 换算成速度，然后一阶逼近
        v_cmd   = (duty * V_MAX) / DUTY_MAX;
        if (dir) v_cmd = -v_cmd;
        v_plant = v_plant + (v_cmd - v_plant) / TAU;
        actual  = v_plant[15:0];
    endtask

    task automatic run_steps(input int n);
        for (int i = 0; i < n; i++) begin
            control_step();
            wait_pos(CTRL_GAP);
        end
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        wait_pos(3);
        rst_n = 1'b1;
        wait_pos(2);
        v_plant = 0;
        actual  = 16'sd0;
    endtask

    initial begin
        $dumpfile("wave_pid.vcd");
        $dumpvars(0, tb_pid_ctrl);

        $display("=== pid_ctrl 测试开始 ===");
        $display("  被控对象模型:  V_MAX=%0d mm/s  TAU=%0d  DUTY_MAX=%0d", V_MAX, TAU, DUTY_MAX);
        $display("  增益:  KP=%0d/256  KI=%0d/256", 256, 32);
        $display("");

        // ── 用例 1：复位 ────────────────────────────────────────────────────
        reset_dut();
        en = 1'b1;
        #1;
        check(duty === '0, "复位后 duty 应为 0");
        check(dir === 1'b0, "复位后 dir 应为 0");
        $display("  [1] 复位后 duty=0 dir=0 ............... %s",
                 (duty === '0 && dir === 1'b0) ? "OK" : "FAIL");

        // ── 用例 2：en=0 → 输出 0 ───────────────────────────────────────────
        target = 16'sd500;
        en = 1'b0;
        run_steps(5);
        #1;
        check(duty === '0, "en=0 时 duty 应为 0");
        $display("  [2] en=0 时 duty=%0d (期望 0) .......... %s", duty, duty == 0 ? "OK" : "FAIL");
        en = 1'b1;

        // ── 用例 3：阶跃响应收敛 ────────────────────────────────────────────
        //     这是 PID 最重要的一条：闭环到底能不能把速度拉到目标附近。
        reset_dut();
        en = 1'b1;
        target = 16'sd500;
        run_steps(120);
        // 稳态误差应该很小；模型有一阶惯性，允许 ±30 mm/s（6%）
        check(actual > 470 && actual < 530,
              $sformatf("目标 500 时实测应收敛到 500 附近，实测 %0d", actual));
        $display("  [3] 阶跃 target=500 → actual=%0d ....... %s",
                 actual, (actual > 470 && actual < 530) ? "OK" : "FAIL");

        // ── 用例 4：输出限幅 ────────────────────────────────────────────────
        //     目标远超电机能力（V_MAX=1000，却要 30000）→ duty 必须饱和在
        //     DUTY_MAX，而不是继续涨（涨了就会在 pwm_gen 里回绕成小占空比）。
        reset_dut();
        en = 1'b1;
        target = 16'sd30000;
        run_steps(60);
        #1;
        check(duty == DUTY_MAX, $sformatf("饱和时 duty 应等于 %0d，实测 %0d", DUTY_MAX, duty));
        $display("  [4] 目标远超能力 duty=%0d (期望 %0d) ... %s",
                 duty, DUTY_MAX, duty == DUTY_MAX ? "OK" : "FAIL");

        // ── 用例 5：⭐ 松开指令后能停下来（anti-windup）────────────────────
        //     先让控制器长时间饱和（积分项会一路涨），再把目标改成 0。
        //     没有 anti-windup 时，积分项要花很久才退回去，车会**继续冲**。
        target = 16'sd0;
        run_steps(80);
        #1;
        check(actual > -20 && actual < 60,
              $sformatf("松开指令后应能停下来，实测 %0d", actual));
        $display("  [5] 松开指令 80 拍后 actual=%0d (期望≈0) %s",
                 actual, (actual > -20 && actual < 60) ? "OK" : "FAIL");

        // ── 用例 6：反向 ────────────────────────────────────────────────────
        reset_dut();
        en = 1'b1;
        target = -16'sd400;
        run_steps(120);
        #1;
        check(dir === 1'b1, "目标为负时 dir 应为 1");
        check(duty > 0, "目标为负时 duty 应大于 0");
        check(actual < -370 && actual > -430,
              $sformatf("目标 -400 应收敛到 -400 附近，实测 %0d", actual));
        $display("  [6] 反向 target=-400 → actual=%0d dir=%0d . %s",
                 actual, dir, (dir === 1'b1 && duty > 0 && actual < -370 && actual > -430) ? "OK" : "FAIL");

        // ── 用例 7：en=0 清积分 ─────────────────────────────────────────────
        //     先跑出一段积分，再 en=0 清掉，然后重新使能。
        //     不清的话，重新使能的第一拍会输出一个巨大值 —— 车会猛冲一下。
        reset_dut();
        en = 1'b1;
        target = 16'sd900;
        run_steps(60);                  // 攒一大坨积分
        en = 1'b0;
        run_steps(3);                   // 期望积分被清掉
        // ⚠️ 判据要设计得能**只**暴露积分残留：
        //    把 target 设成当前实测速度 → 误差为 0 → P 项和 D 项都是 0。
        //    此时若 duty 还很大，只可能来自**没被清掉的积分项**。
        //    （若把 target 固定成 0，控制器会因为轮子还在转而正常刹车，
        //      那测的是刹车能力，不是积分清零 —— 这个坑我踩过一次。）
        target = actual;
        en = 1'b1;
        pulse_tick();
        wait_pos(2);
        check(duty < 50, $sformatf("误差为 0 时 duty 应≈0（残留积分会暴露），实测 %0d", duty));
        $display("  [7] en 恢复后首拍 duty=%0d (误差=0，期望 <50) %s", duty, duty < 50 ? "OK" : "FAIL");

        // ── 用例 8：稳态误差 ────────────────────────────────────────────────
        reset_dut();
        en = 1'b1;
        target = 16'sd300;
        run_steps(150);
        #1;
        check(actual > 285 && actual < 315,
              $sformatf("稳态误差应小于 5%%，实测 actual=%0d", actual));
        $display("  [8] target=300 稳态 actual=%0d (误差<5%%)  %s",
                 actual, (actual > 285 && actual < 315) ? "OK" : "FAIL");

        // ── 汇总 ────────────────────────────────────────────────────────────
        $display("");
        if (errors == 0)
            $display("PASS  pid_ctrl 全部用例通过");
        else
            $display("FAIL  pid_ctrl 有 %0d 项未通过", errors);

        $finish;
    end

    initial begin
        #2000000;
        errors++;
        $display("");
        $display("FAIL  pid_ctrl 仿真超时（有用例卡死，未跑完）");
        $finish;
    end

endmodule
