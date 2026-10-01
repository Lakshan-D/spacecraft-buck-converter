// Closed-loop testbench: RTL controller + behavioural buck plant.
// Scenarios: start-up at full load, load steps, line steps.
// Writes results/loop_log.csv (1 us) and results/golden_log.csv (per control tick).
`timescale 1ns/1ps
module tb_buck_loop;
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;                       // 100 MHz

    real vin, rload;
    wire [63:0] vin_b   = $realtobits(vin);
    wire [63:0] rload_b = $realtobits(rload);
    wire [63:0] vo_b, il_b;
    wire [11:0] adc;
    wire        pwm, mism;

    buck_ctrl_top #(.TMR(1)) dut (.clk(clk), .rst(rst), .adc(adc), .pwm(pwm), .tmr_mismatch(mism));
    buck_plant plant (.clk(clk), .pwm(pwm), .vin_b(vin_b), .rload_b(rload_b),
                      .adc(adc), .vo_b(vo_b), .il_b(il_b));

    integer f_loop, f_gold, n = 0;
    reg        tick_q = 0;
    reg [11:0] adc_q  = 0;

    initial begin
        f_loop = $fopen("results/loop_log.csv", "w");
        f_gold = $fopen("results/golden_log.csv", "w");
        $fwrite(f_loop, "t_us,vo,il,duty,vin,rload\n");
        $fwrite(f_gold, "adc,duty\n");
    end

    // Golden log: ADC code seen at the tick edge and the duty the RTL produced from it
    always @(posedge clk) begin
        if (!rst && tick_q) $fwrite(f_gold, "%0d,%0d\n", adc_q, dut.duty);
        tick_q <= dut.tick;
        adc_q  <= adc;
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
        $fclose(f_gold);
        $display("tb_buck_loop done");
        $finish;
    end
endmodule
