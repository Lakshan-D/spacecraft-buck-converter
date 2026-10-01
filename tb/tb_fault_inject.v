// Single-event-upset (SEU) fault injection.
// Run with -Ptb_fault_inject.TMR=0 (plain PID) or =1 (TMR + voter + scrub).
// After the loop settles, flip ONE random bit in ONE random state copy at a random
// time, watch Vout for WINDOW clocks, log the result, repeat N times.
// The same seed gives the same bit/time sequence for both runs.
`timescale 1ns/1ps
module tb_fault_inject;
    parameter TMR    = 1;
    parameter N      = 200;                    // number of injected upsets
    parameter WINDOW = 30000;                  // clocks observed per upset (300 us)
    parameter TAIL   = 5000;                   // last 50 us used to judge recovery
    parameter SEED   = 12345;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    real vin = 28.0, rload = 1.667;
    wire [63:0] vin_b   = $realtobits(vin);
    wire [63:0] rload_b = $realtobits(rload);
    wire [63:0] vo_b, il_b;
    wire [11:0] adc;
    wire        pwm, mism;

    buck_ctrl_top #(.TMR(TMR)) dut (.clk(clk), .rst(rst), .adc(adc), .pwm(pwm), .tmr_mismatch(mism));
    buck_plant plant (.clk(clk), .pwm(pwm), .vin_b(vin_b), .rload_b(rload_b),
                      .adc(adc), .vo_b(vo_b), .il_b(il_b));

    localparam W = 58;
    integer seed = SEED;
    integer i, k, copy, bit_i, delay_clk, f;
    real    dev, peak, tail_peak;
    reg     detected;
    reg [W-1:0] mask;
    reg [W-1:0] tmp;

    initial begin
        f = $fopen(TMR ? "results/fault_tmr1.csv" : "results/fault_tmr0.csv", "w");
        $fwrite(f, "idx,copy,bit,peak_mV,tail_mV,detected\n");
        #100 rst = 0;
        repeat (150000) @(posedge clk);            // 1.5 ms: let the loop settle

        for (i = 0; i < N; i = i + 1) begin
            peak = 0.0; tail_peak = 0.0; detected = 0;
            delay_clk = {$random(seed)} % 1000;    // random phase vs the switching period
            repeat (delay_clk) @(posedge clk);

            bit_i = {$random(seed)} % W;
            copy  = (TMR != 0) ? ({$random(seed)} % 3) : 0;
            mask  = {W{1'b0}};
            mask[bit_i] = 1'b1;

            @(negedge clk);                        // inject away from the active edge
            if (copy == 0)      begin tmp = dut.u_pid.state0; dut.u_pid.state0 = tmp ^ mask; end
            else if (copy == 1) begin tmp = dut.u_pid.state1; dut.u_pid.state1 = tmp ^ mask; end
            else                begin tmp = dut.u_pid.state2; dut.u_pid.state2 = tmp ^ mask; end

            for (k = 0; k < WINDOW; k = k + 1) begin
                @(posedge clk);
                dev = $bitstoreal(vo_b) - 5.0;
                if (dev < 0.0) dev = -dev;
                if (dev > peak) peak = dev;
                if (k >= WINDOW - TAIL && dev > tail_peak) tail_peak = dev;
                if (mism) detected = 1;
            end
            $fwrite(f, "%0d,%0d,%0d,%0.1f,%0.1f,%0d\n", i, copy, bit_i, peak * 1000.0, tail_peak * 1000.0, detected);
        end
        $fclose(f);
        $display("tb_fault_inject TMR=%0d done", TMR);
        $finish;
    end
endmodule
