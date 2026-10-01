// Top level: ADC code in, PWM out. Synthesisable (no real numbers, no delays).
module buck_ctrl_top #(
    parameter TMR    = 1,
    parameter PERIOD = 500
) (
    input         clk,
    input         rst,
    input  [11:0] adc,
    output        pwm,
    output        tmr_mismatch
);
    wire        tick;
    wire [9:0]  duty;

    pwm_gen #(.PERIOD(PERIOD)) u_pwm (
        .clk(clk), .rst(rst), .duty(duty), .tick(tick), .pwm(pwm)
    );

    pid_ctrl #(.TMR(TMR)) u_pid (
        .clk(clk), .rst(rst), .tick(tick), .adc(adc),
        .duty(duty), .tmr_mismatch(tmr_mismatch)
    );
endmodule
