// Free-running PWM generator.
//   PERIOD clock cycles per switching period (100 MHz clk, PERIOD=500 -> 200 kHz).
//   pwm is high while cnt < duty (duty in clock counts, 0..PERIOD).
//   tick pulses for one clock in the last cycle of each period. The controller
//   samples the ADC and updates the duty on that edge, so the new duty is in
//   force from the first cycle of the next period.
module pwm_gen #(
    parameter PERIOD = 500
) (
    input        clk,
    input        rst,
    input  [9:0] duty,
    output       tick,
    output       pwm
);
    reg [9:0] cnt;
    assign tick = (cnt == PERIOD - 1);
    assign pwm  = (cnt < duty);

    always @(posedge clk) begin
        if (rst)       cnt <= 10'd0;
        else if (tick) cnt <= 10'd0;
        else           cnt <= cnt + 10'd1;
    end
endmodule
