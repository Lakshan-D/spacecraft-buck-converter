// Fixed-point PID voltage-mode controller with optional TMR on all state.
//
//   e        = VREF - adc                          (ADC codes)
//   integ'   = clamp(integ + KI*e, 0, DMAX<<SHIFT) (anti-windup by clamping)
//   u        = (KP*e + KD*(e - e_prev) + integ') >>> SHIFT
//   duty'    = clamp(u, 0, DMAX)                   (PWM counts)
//
// Gains are signed integers scaled by 2^SHIFT (counts per ADC code).
// Defaults: KP=0.04, KI=0.004, KD=0.40 in Q16.
//
// State (integ, e_prev, duty) is packed into one vector and stored three times.
// With TMR=1 every use of the state goes through a bitwise majority voter and
// the voted result is written back to all three copies on each tick, so an
// upset is scrubbed within one switching period. With TMR=0 only copy 0 is used.
module pid_ctrl #(
    parameter TMR             = 1,
    parameter [11:0] VREF     = 12'd2560,        // 5.000 V with 8 V full-scale, 12-bit ADC
    parameter signed [17:0] KP = 18'sd2621,      // 0.040 * 65536
    parameter signed [17:0] KI = 18'sd262,       // 0.004 * 65536
    parameter signed [17:0] KD = 18'sd26214,     // 0.400 * 65536
    parameter SHIFT           = 16,
    parameter [9:0] DMAX      = 10'd400          // 80 % max duty
) (
    input         clk,
    input         rst,
    input         tick,
    input  [11:0] adc,
    output [9:0]  duty,
    output        tmr_mismatch
);
    localparam W = 32 + 16 + 10;

    reg  [W-1:0] state0, state1, state2;
    wire [W-1:0] voted;

    tmr_voter #(.W(W)) u_vote (.a(state0), .b(state1), .c(state2), .y(voted));

    wire [W-1:0] st = (TMR != 0) ? voted : state0;

    wire signed [31:0] integ_q  = st[57:26];
    wire signed [15:0] eprev_q  = st[25:10];

    // Everything below is done in 48-bit signed so corrupted state cannot overflow.
    wire signed [47:0] vref_s  = {36'd0, VREF};
    wire signed [47:0] adc_s   = {36'd0, adc};
    wire signed [47:0] e_s     = vref_s - adc_s;
    wire signed [47:0] eprev_s = {{32{eprev_q[15]}}, eprev_q};
    wire signed [47:0] integ_s = {{16{integ_q[31]}}, integ_q};
    wire signed [47:0] kp_s    = KP;
    wire signed [47:0] ki_s    = KI;
    wire signed [47:0] kd_s    = KD;
    wire signed [47:0] dmax_s  = {38'd0, DMAX};
    wire signed [47:0] imax_s  = dmax_s <<< SHIFT;

    wire signed [47:0] integ_raw = integ_s + ki_s * e_s;
    wire signed [47:0] integ_n   = (integ_raw < 0)      ? 48'sd0 :
                                   (integ_raw > imax_s) ? imax_s : integ_raw;

    wire signed [47:0] u_raw = (kp_s * e_s + kd_s * (e_s - eprev_s) + integ_n) >>> SHIFT;
    wire signed [47:0] u_c   = (u_raw < 0) ? 48'sd0 : (u_raw > dmax_s) ? dmax_s : u_raw;

    wire [W-1:0] next_state = {integ_n[31:0], e_s[15:0], u_c[9:0]};

    always @(posedge clk) begin
        if (rst) begin
            state0 <= {W{1'b0}};
            state1 <= {W{1'b0}};
            state2 <= {W{1'b0}};
        end else if (tick) begin
            state0 <= next_state;
            state1 <= next_state;
            state2 <= next_state;
        end
    end

    assign duty         = st[9:0];
    assign tmr_mismatch = (state0 != state1) | (state1 != state2) | (state0 != state2);
endmodule
