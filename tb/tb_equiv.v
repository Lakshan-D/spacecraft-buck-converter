// Equivalence check: pid_ctrl_seq.v (multi-cycle, for synthesis) against
// pid_ctrl.v (single-cycle reference). Both get the same random state (all 70
// bits random, so corrupted states after an upset are covered too), the same
// random ADC codes and one tick. The new state each one writes must match bit
// for bit. Some state copies are made to disagree so the TMR voter path is
// exercised as well.
// Run with -Ptb_equiv.TMR=.. -Ptb_equiv.FF_EN=.. -Ptb_equiv.SS_STEP=..
`timescale 1ns/1ps
module tb_equiv;
    parameter TMR = 1, FF_EN = 1, SS_STEP = 16, N = 20000, SEED = 7;
    localparam W = 70;

    reg clk = 0, rst = 1, tick = 0;
    always #5 clk = ~clk;
    reg  [11:0] adc, vin;
    wire [9:0]  duty_c, duty_s;
    wire        mm_c, mm_s, upd;

    pid_ctrl     #(.TMR(TMR), .FF_EN(FF_EN), .SS_STEP(SS_STEP)) ref_dut (
        .clk(clk), .rst(rst), .tick(tick), .adc(adc), .vin(vin), .duty(duty_c), .tmr_mismatch(mm_c));
    pid_ctrl_seq #(.TMR(TMR), .FF_EN(FF_EN), .SS_STEP(SS_STEP)) seq_dut (
        .clk(clk), .rst(rst), .tick(tick), .adc(adc), .vin(vin), .duty(duty_s), .tmr_mismatch(mm_s), .upd(upd));

    integer seed = SEED, i, bad = 0, mode;
    reg [W-1:0] s0, s1, s2;
    reg [31:0]  ri;
    reg [15:0]  re;
    reg [11:0]  rq;
    integer     e_i, d_i, refn_i, imax_i;

    function [W-1:0] rnd70; input integer dummy;
        rnd70 = {$random(seed), $random(seed), $random(seed)};
    endfunction

    initial begin
        adc = 0; vin = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        for (i = 0; i < N; i = i + 1) begin
            mode = {$random(seed)} % 7;
            // state: mostly random; sometimes "realistic" small values near steady state
            s0 = rnd70(0);
            if (mode == 0) begin
                ri = 32'd2000000 + ({$random(seed)} % 400000);
                re = $random(seed) % 50;
                s0 = {12'd2560, ri, re, 10'd90};
            end
            s1 = s0; s2 = s0;
            if (TMR != 0 && mode == 1) s1 = s0 ^ (70'd1 << ({$random(seed)} % W));   // one copy upset
            if (TMR != 0 && mode == 2) s2 = rnd70(0);                                // one copy garbage
            adc = $random(seed);
            vin = (mode == 3) ? 12'd0 : $random(seed);                               // include vin = 0
            if (mode == 0) begin adc = 2560 + ($random(seed) % 200); vin = 2200 + ({$random(seed)} % 1400); end
            // Directed corners (TMR copies left equal):
            //  4: integrator lands exactly on, or 1-2 counts either side of, +/- IMAX
            //  5: soft start reference lands exactly on, or next to, VREF
            //  6: feedforward divide is exact (no remainder) or 1 count off
            if (mode == 4 || mode == 5 || mode == 6) begin
                imax_i = 400 * 65536;
                rq     = (mode == 5) ? (2560 - SS_STEP + ($random(seed) % 3)) : 12'd2560;
                refn_i = (SS_STEP == 0) ? 2560 : ((rq + SS_STEP >= 2560) ? 2560 : rq + SS_STEP);
                adc    = (mode == 6) ? 12'd2560 : 2560 + ($random(seed) % 100);
                e_i    = refn_i - adc;
                d_i    = ($random(seed) % 3);
                ri     = (({$random(seed)} % 2) && FF_EN != 0) ? (-imax_i - 524 * e_i + d_i) : (imax_i - 524 * e_i + d_i);
                re     = $random(seed) % 20;
                s0     = {rq, ri, re, 10'd90};
                s1 = s0; s2 = s0;
                vin    = (mode == 6) ? (125 * (1 + {$random(seed)} % 30)) + ($random(seed) % 2) : 12'd2800;
            end
            @(negedge clk);
            ref_dut.r0.q = s0; ref_dut.r1.q = s1; ref_dut.r2.q = s2;
            seq_dut.r0.q = s0; seq_dut.r1.q = s1; seq_dut.r2.q = s2;
            tick = 1;
            @(negedge clk);
            tick = 0;
            wait (upd == 1'b1);
            @(negedge clk);
            if (seq_dut.state0 !== ref_dut.state0 || seq_dut.state1 !== ref_dut.state1 ||
                seq_dut.state2 !== ref_dut.state2) begin
                bad = bad + 1;
                if (bad <= 5) $display("MISMATCH i=%0d mode=%0d adc=%0d vin=%0d ref=%h seq=%h", i, mode, adc, vin, ref_dut.state0, seq_dut.state0);
            end
        end
        $display("tb_equiv TMR=%0d FF_EN=%0d SS_STEP=%0d: %0d / %0d ticks identical", TMR, FF_EN, SS_STEP, N - bad, N);
        $finish;
    end
endmodule
