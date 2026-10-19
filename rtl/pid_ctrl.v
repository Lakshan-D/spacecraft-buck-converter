// Fixed-point PID voltage-mode controller with Vin feedforward, soft start and
// optional TMR on all state.
//
//   ref'     = min(ref + SS_STEP, VREF)            (soft start ramp; SS_STEP=0 -> ref' = VREF)
//   e        = ref' - adc                          (ADC codes)
//   integ'   = clamp(integ + KI*e, -IMAX, IMAX)    (anti-windup by clamping)
//   ff       = ref' * PERIOD * VIN_CPV / (ADC_CPV * vin)   (Vin feedforward, duty counts)
//   u        = ((KP*e + KD*(e - e_prev) + integ') >>> SHIFT) + ff
//   duty'    = clamp(u, 0, DMAX)                   (PWM counts)
//
// Feedforward: a buck has Vout = D * Vin, so the duty that gives the wanted Vout is
// D = Vout / Vin. The feedforward term supplies that duty directly from the measured
// Vin, so a bus step moves the duty at the next tick instead of waiting for the
// error to build up. The PID only has to trim what is left (diode and DCR drops).
// FF_EN = 0 and SS_STEP = 0 give the original iteration 2 controller bit for bit
// (the integrator lower clamp goes back to 0).
//
// Gains are signed integers scaled by 2^SHIFT (counts per ADC code).
// Defaults: KP=0.10, KI=0.008, KD=1.60 in Q16 (retuned for Cout = 150 uF).
//
// State (integ, e_prev, duty, ref) is packed into one vector and stored three times.
// With TMR=1 every use of the state goes through a bitwise majority voter and
// the voted result is written back to all three copies on each tick, so an
// upset is scrubbed within one switching period. With TMR=0 only copy 0 is used.
module pid_ctrl #(
    parameter TMR             = 1,
    parameter FF_EN           = 1,               // 1 = Vin feedforward on
    parameter SS_STEP         = 16,              // soft start ramp, ADC codes per tick (0 = off)
    parameter PERIOD          = 500,             // PWM counts per switching period
    parameter VIN_CPV         = 100,             // Vin ADC codes per volt (28 V -> 2800)
    parameter ADC_CPV         = 512,             // Vout ADC codes per volt (5 V -> 2560)
    parameter [11:0] VREF     = 12'd2560,        // 5.000 V with 8 V full-scale, 12-bit ADC
    parameter signed [17:0] KP = 18'sd6554,      // 0.100 * 65536
    parameter signed [17:0] KI = 18'sd524,       // 0.008 * 65536
    parameter signed [17:0] KD = 18'sd104858,    // 1.600 * 65536
    parameter SHIFT           = 16,
    parameter [9:0] DMAX      = 10'd400          // 80 % max duty
) (
    input         clk,
    input         rst,
    input         tick,
    input  [11:0] adc,
    input  [11:0] vin,
    output [9:0]  duty,
    output        tmr_mismatch
);
    localparam W = 12 + 32 + 16 + 10;            // ref, integ, e_prev, duty

    reg  [W-1:0] state0, state1, state2;
    wire [W-1:0] voted;

    tmr_voter #(.W(W)) u_vote (.a(state0), .b(state1), .c(state2), .y(voted));

    wire [W-1:0] st = (TMR != 0) ? voted : state0;

    wire        [11:0] ref_q   = st[69:58];
    wire signed [31:0] integ_q = st[57:26];
    wire signed [15:0] eprev_q = st[25:10];

    // Everything below is done in 48-bit so corrupted state cannot overflow.
    wire        [47:0] vref_u  = {36'd0, VREF};
    wire        [47:0] ref_inc = {36'd0, ref_q} + SS_STEP;
    wire        [47:0] ref_n_u = (SS_STEP == 0)      ? vref_u :
                                 (ref_inc >= vref_u) ? vref_u : ref_inc;

    wire signed [47:0] ref_n_s = $signed(ref_n_u);
    wire signed [47:0] adc_s   = {36'd0, adc};
    wire signed [47:0] e_s     = ref_n_s - adc_s;
    wire signed [47:0] eprev_s = {{32{eprev_q[15]}}, eprev_q};
    wire signed [47:0] integ_s = {{16{integ_q[31]}}, integ_q};
    wire signed [47:0] kp_s    = KP;
    wire signed [47:0] ki_s    = KI;
    wire signed [47:0] kd_s    = KD;
    wire signed [47:0] dmax_s  = {38'd0, DMAX};
    wire signed [47:0] imax_s  = dmax_s <<< SHIFT;
    wire signed [47:0] imin_s  = (FF_EN != 0) ? -imax_s : 48'sd0;

    wire signed [47:0] integ_raw = integ_s + ki_s * e_s;
    wire signed [47:0] integ_n   = (integ_raw < imin_s) ? imin_s :
                                   (integ_raw > imax_s) ? imax_s : integ_raw;

    // Vin feedforward: duty counts = ref * PERIOD * VIN_CPV / (ADC_CPV * vin)
    wire        [47:0] ff_num = ref_n_u * PERIOD * VIN_CPV;
    wire        [47:0] ff_den = ADC_CPV * {36'd0, vin};
    wire        [47:0] ff_div = ((FF_EN != 0) && (ff_den != 48'd0)) ? (ff_num / ff_den) : 48'd0;
    wire        [47:0] ff_cl  = (ff_div > {38'd0, DMAX}) ? {38'd0, DMAX} : ff_div;
    wire signed [47:0] ff_s   = $signed(ff_cl);

    wire signed [47:0] pid_sum = (kp_s * e_s + kd_s * (e_s - eprev_s) + integ_n) >>> SHIFT;
    wire signed [47:0] u_raw   = pid_sum + ff_s;
    wire signed [47:0] u_c     = (u_raw < 0) ? 48'sd0 : (u_raw > dmax_s) ? dmax_s : u_raw;

    wire [W-1:0] next_state = {ref_n_u[11:0], integ_n[31:0], e_s[15:0], u_c[9:0]};

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
