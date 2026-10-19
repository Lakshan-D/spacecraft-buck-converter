// Top level: ADC codes in (Vout and Vin), PWM out. Synthesisable (no real numbers, no delays).
module buck_ctrl_top #(
    parameter TMR     = 1,
    parameter PERIOD  = 500,
    parameter FF_EN   = 1,      // Vin feedforward
    parameter SS_STEP = 16      // soft start ramp, ADC codes per switching period (0 = off)
) (
    input         clk,
    input         rst,
    input  [11:0] adc,          // Vout, 512 codes per volt
    input  [11:0] vin_adc,      // Vin, 100 codes per volt
    output        pwm,
    output        tmr_mismatch
);
    wire        tick;
    wire [9:0]  duty;

    pwm_gen #(.PERIOD(PERIOD)) u_pwm (
        .clk(clk), .rst(rst), .duty(duty), .tick(tick), .pwm(pwm)
    );

    pid_ctrl #(.TMR(TMR), .FF_EN(FF_EN), .SS_STEP(SS_STEP), .PERIOD(PERIOD)) u_pid (
        .clk(clk), .rst(rst), .tick(tick), .adc(adc), .vin(vin_adc),
        .duty(duty), .tmr_mismatch(tmr_mismatch)
    );
endmodule
