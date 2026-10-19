// Closed-loop testbench: RTL controller + behavioural buck plant.
// Scenarios: start-up at full load, load steps, line steps.
// Writes results/loop_log.csv (1 us) and results/golden_log.csv (per control tick).
// FF_EN / SS_STEP select feedforward and soft start. With +tag=NAME the 1 us log goes to
// results/ablation_NAME.csv and no golden log is written (used by `make ablate`).
`timescale 1ns/1ps
module tb_buck_loop;
    parameter FF_EN   = 1;
    parameter SS_STEP = 16;
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;                       // 100 MHz

    real vin, rload;
    wire [63:0] vin_b   = $realtobits(vin);
    wire [63:0] rload_b = $realtobits(rload);
    wire [63:0] vo_b, il_b;
    wire [11:0] adc, vin_adc;
    wire        pwm, mism;

    buck_ctrl_top #(.TMR(1), .FF_EN(FF_EN), .SS_STEP(SS_STEP)) dut (
        .clk(clk), .rst(rst), .adc(adc), .vin_adc(vin_adc), .pwm(pwm), .tmr_mismatch(mism));
    buck_plant plant (.clk(clk), .pwm(pwm), .vin_b(vin_b), .rload_b(rload_b),
                      .adc(adc), .vin_adc(vin_adc), .vo_b(vo_b), .il_b(il_b));

    integer f_loop, f_gold, n = 0;
    reg        tick_q = 0;
    reg [11:0] adc_q  = 0;
    reg [11:0] vin_q  = 0;
    reg [8*48-1:0] tag, path;
    reg        use_tag;

    initial begin
        use_tag = $value$plusargs("tag=%s", tag);
        if (use_tag) $sformat(path, "results/ablation_%0s.csv", tag);
        else        $sformat(path, "results/loop_log.csv");
        f_loop = $fopen(path, "w");
        $fwrite(f_loop, "t_us,vo,il,duty,vin,rload\n");
        if (!use_tag) begin
            f_gold = $fopen("results/golden_log.csv", "w");
            $fwrite(f_gold, "adc,vin,duty\n");
        end
    end

    // Golden log: ADC codes seen at the tick edge and the duty the RTL produced from them
    always @(posedge clk) begin
        if (!use_tag && !rst && tick_q) $fwrite(f_gold, "%0d,%0d,%0d\n", adc_q, vin_q, dut.duty);
        tick_q <= dut.tick;
        adc_q  <= adc;
        vin_q  <= vin_adc;
    end

    // 1 us log
    always @(posedge clk) begin
        n <= n + 1;
        if (n % 100 == 0)
            $fwrite(f_loop, "%0.3f,%0.5f,%0.5f,%0d,%0.1f,%0.3f\n",
                    $realtime / 1000.0, $bitstoreal(vo_b), $bitstoreal(il_b), dut.duty, vin, rload);
    end

    initial begin
        vin = 28.0; rload = 1.667;              // 28 V, 3 A load
        #100 rst = 0;
        #1500000 rload = 16.67;                 // 1.5 ms: load 3 A -> 0.3 A
        #1000000 rload = 1.667;                 // 2.5 ms: load 0.3 A -> 3 A
        #1000000 vin = 22.0;                    // 3.5 ms: bus 28 V -> 22 V
        #1000000 vin = 36.0;                    // 4.5 ms: bus 22 V -> 36 V
        #1000000 vin = 28.0;                    // 5.5 ms: bus 36 V -> 28 V
        #1000000;                               // 6.5 ms end
        $fclose(f_loop);
        if (!use_tag) $fclose(f_gold);
        $display("tb_buck_loop done");
        $finish;
    end
endmodule
