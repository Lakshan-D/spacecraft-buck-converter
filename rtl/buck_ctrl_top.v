// Top level: ADC codes in (Vout and Vin), PWM out. Synthesisable (no real numbers, no delays).
// SEQ selects the controller architecture. Both compute the same control law bit for bit
// (tb/tb_equiv.v):
//   SEQ = 0  pid_ctrl.v      whole update in one clock. Reference; places and routes at ~4.7 MHz.
//   SEQ = 1  pid_ctrl_seq.v  same maths spread over 15 clocks. 117-123 MHz on ECP5 (target 100).
// See docs/synthesis_report.md.
// ctrl_upd pulses for one clock when the controller writes its new state.
module buck_ctrl_top #(
    parameter TMR     = 1,
    parameter PERIOD  = 500,
    parameter FF_EN   = 1,      // Vin feedforward
    parameter SS_STEP = 16,     // soft start ramp, ADC codes per switching period (0 = off)
    parameter SEQ     = 0       // 0 = single-cycle controller, 1 = multi-cycle (for synthesis)
) (
    input         clk,
    input         rst,
    input  [11:0] adc,          // Vout, 512 codes per volt
    input  [11:0] vin_adc,      // Vin, 100 codes per volt
    output        pwm,
    output        tmr_mismatch,
    output        ctrl_upd
);
    wire        tick;
    wire [9:0]  duty;

    pwm_gen #(.PERIOD(PERIOD)) u_pwm (
        .clk(clk), .rst(rst), .duty(duty), .tick(tick), .pwm(pwm)
    );

    generate
        if (SEQ != 0) begin : g_seq
            pid_ctrl_seq #(.TMR(TMR), .FF_EN(FF_EN), .SS_STEP(SS_STEP), .PERIOD(PERIOD)) u_pid (
                .clk(clk), .rst(rst), .tick(tick), .adc(adc), .vin(vin_adc),
                .duty(duty), .tmr_mismatch(tmr_mismatch), .upd(ctrl_upd)
            );
        end else begin : g_comb
            reg upd_q;
            always @(posedge clk) upd_q <= rst ? 1'b0 : tick;
            assign ctrl_upd = upd_q;
            pid_ctrl #(.TMR(TMR), .FF_EN(FF_EN), .SS_STEP(SS_STEP), .PERIOD(PERIOD)) u_pid (
                .clk(clk), .rst(rst), .tick(tick), .adc(adc), .vin(vin_adc),
                .duty(duty), .tmr_mismatch(tmr_mismatch)
            );
        end
    endgenerate
endmodule
