// Multi-cycle (sequential) version of pid_ctrl.v, for FPGA synthesis.
//
// pid_ctrl.v computes the whole control law in ONE clock cycle: three wide
// multiplies, several 48-bit adds and compares, and a 48-bit divide, all in a
// single combinational path. That simulates fine but places and routes at about
// 4.8 MHz on an ECP5, far below the 100 MHz the PWM counter runs at
// (docs/synthesis_report.md).
//
// The controller only has to produce one result per switching period (500
// clocks), so this version spreads the same maths over 15 clocks, with at most
// one wide add, compare or multiply between registers:
//
//   step 0   tick: latch adc, vin and the (voted) state
//   step 1   soft start reference ref' = min(ref + SS_STEP, VREF)
//   step 2   e = ref' - adc;  feedforward numerator ref' * PERIOD * VIN_CPV,
//            denominator ADC_CPV * vin
//   step 3   e - e_prev;  KI*e, KP*e (DSP);  divide overflow check
//   step 4   KD*(e - e_prev) (DSP);  integ + KI*e
//   step 5   integrator clamp;  KP*e + KD*(e - e_prev)
//   step 6   PID sum >>> SHIFT
//   4..12    feedforward divide, one quotient bit per step (restoring)
//   step 13  u = PID + ff
//   step 14  clamp u to [0, DMAX], write the new state to all three copies (tmr_copy)
//
// The result is bit-identical to pid_ctrl.v for every input and every state,
// including corrupted state after an upset (tb/tb_equiv.v checks 120 000 random
// and corner-case updates). The only difference is timing: the new duty takes
// effect 14 clocks (140 ns) into the next switching period instead of at its start.
//
// Narrow datapaths, all exact because the values provably fit:
//   e in [-4095, 4111] (16 bits); e - e_prev in [-36863, 36879] (18 bits)
//   numerator <= 4111 * 50000 < 2^28; denominator << 9 <= 512 * 4095 * 512 < 2^31
// The divide only needs 9 quotient bits plus an overflow check, because the
// result is clamped to DMAX (400 < 512):  num >= 512*den -> quotient > DMAX.
module pid_ctrl_seq #(
    parameter TMR             = 1,
    parameter FF_EN           = 1,
    parameter SS_STEP         = 16,
    parameter PERIOD          = 500,
    parameter VIN_CPV         = 100,
    parameter ADC_CPV         = 512,
    parameter [11:0] VREF     = 12'd2560,
    parameter signed [17:0] KP = 18'sd6554,
    parameter signed [17:0] KI = 18'sd524,
    parameter signed [17:0] KD = 18'sd104858,
    parameter SHIFT           = 16,
    parameter [9:0] DMAX      = 10'd400
) (
    input         clk,
    input         rst,
    input         tick,
    input  [11:0] adc,
    input  [11:0] vin,
    output [9:0]  duty,
    output        tmr_mismatch,
    output reg    upd                          // one-clock pulse when the new state is written
);
    localparam W    = 12 + 32 + 16 + 10;       // ref, integ, e_prev, duty (same packing as pid_ctrl.v)
    localparam QB   = 9;                       // quotient bits; 2^QB must be > DMAX
    localparam LAST = 4'd14;

    // Three copies of the state, each in its own tmr_copy instance so synthesis cannot
    // merge them (see tmr_copy.v). Fault injection writes r0.q / r1.q / r2.q.
    wire [W-1:0] state0, state1, state2;
    wire         st_load;
    wire [W-1:0] st_next;
    tmr_copy #(.W(W)) r0 (.clk(clk), .rst(rst), .en(st_load), .d(st_next), .q(state0));
    tmr_copy #(.W(W)) r1 (.clk(clk), .rst(rst), .en(st_load), .d(st_next), .q(state1));
    tmr_copy #(.W(W)) r2 (.clk(clk), .rst(rst), .en(st_load), .d(st_next), .q(state2));
    wire [W-1:0] voted;
    tmr_voter #(.W(W)) u_vote (.a(state0), .b(state1), .c(state2), .y(voted));
    wire [W-1:0] st = (TMR != 0) ? voted : state0;

    reg       busy;
    reg [3:0] step;

    // step 0
    reg [11:0]  adc_r, vin_r;
    reg [W-1:0] st_r;
    // step 1
    reg        [12:0] ref_n;                   // <= 4111
    reg signed [47:0] integ_s;
    reg signed [17:0] eprev_s;
    // step 2
    reg signed [15:0] e_s;
    reg        [31:0] ff_rem, ff_den, ff_dsh;
    reg               ff_zero;
    // steps 3..13
    reg signed [17:0] ediff_s;
    reg signed [47:0] ki_e, kp_e, kd_d, integ_raw, integ_n, pd_sum, pid_sum, u_raw;
    // divider
    reg [QB-1:0] q;
    reg          ff_ovf;

    wire signed [47:0] dmax_s = {38'd0, DMAX};
    wire signed [47:0] imax_s = dmax_s <<< SHIFT;
    wire signed [47:0] imin_s = (FF_EN != 0) ? -imax_s : 48'sd0;

    // step 1 combinational (same expressions as pid_ctrl.v)
    wire [11:0] ref_q   = st_r[69:58];
    wire [12:0] ref_inc = {1'b0, ref_q} + SS_STEP;
    wire [12:0] ref_c   = (SS_STEP == 0)    ? {1'b0, VREF} :
                          (ref_inc >= VREF) ? {1'b0, VREF} : ref_inc;

    // one restoring divide step: subtract if it does not go negative, shift in the quotient bit
    wire [32:0] ff_try = {1'b0, ff_rem} - {1'b0, ff_dsh};
    wire        ff_ge  = ~ff_try[32];

    // feedforward term, min(quotient, DMAX); 0 when off or vin = 0
    wire [9:0]  ff_cl  = ff_zero ? 10'd0 : (ff_ovf || ({1'b0, q} > DMAX)) ? DMAX : {1'b0, q};

    wire signed [47:0] u_c = u_raw[47] ? 48'sd0 : (u_raw > dmax_s) ? dmax_s : u_raw;
    wire [W-1:0] next_state = {ref_n[11:0], integ_n[31:0], e_s[15:0], u_c[9:0]};

    always @(posedge clk) begin
        upd <= 1'b0;
        if (rst) begin
            busy   <= 1'b0;
            step   <= 4'd0;
        end else if (!busy) begin
            if (tick) begin
                adc_r <= adc;
                vin_r <= vin;
                st_r  <= st;
                busy  <= 1'b1;
                step  <= 4'd1;
            end
        end else begin
            step <= step + 4'd1;
            case (step)
                4'd1: begin
                    ref_n   <= ref_c;
                    integ_s <= {{16{st_r[57]}}, st_r[57:26]};
                    eprev_s <= {{2{st_r[25]}}, st_r[25:10]};
                end
                4'd2: begin
                    e_s     <= $signed({3'b000, ref_n}) - $signed({4'b0000, adc_r});
                    ff_rem  <= ref_n * (PERIOD * VIN_CPV);
                    ff_den  <= ADC_CPV * vin_r;
                    ff_zero <= (FF_EN == 0) || (vin_r == 12'd0);
                end
                4'd3: begin
                    ediff_s <= e_s - eprev_s;
                    ki_e    <= KI * e_s;
                    kp_e    <= KP * e_s;
                    ff_ovf  <= ({1'b0, ff_rem} >= ({1'b0, ff_den} << QB));
                    ff_dsh  <= ff_den << (QB - 1);
                    q       <= {QB{1'b0}};
                end
                4'd4: begin
                    kd_d      <= KD * ediff_s;
                    integ_raw <= integ_s + ki_e;
                end
                4'd5: begin
                    integ_n <= (integ_raw < imin_s) ? imin_s :
                               (integ_raw > imax_s) ? imax_s : integ_raw;
                    pd_sum  <= kp_e + kd_d;
                end
                4'd6:  pid_sum <= (pd_sum + integ_n) >>> SHIFT;
                4'd13: u_raw   <= pid_sum + $signed({38'd0, ff_cl});
                LAST: begin
                    upd    <= 1'b1;
                    busy   <= 1'b0;
                    step   <= 4'd0;
                end
                default: ;
            endcase

            // divider: steps 4..12 produce quotient bits 8..0
            if (step >= 4'd4 && step <= 4'd12) begin
                if (ff_ge) ff_rem <= ff_try[31:0];
                q      <= {q[QB-2:0], ff_ge};
                ff_dsh <= ff_dsh >> 1;
            end
        end
    end

    // the three copies load on the last step (same cycle upd is set)
    assign st_load = busy && (step == LAST);
    assign st_next = next_state;

    assign duty         = st[9:0];
    assign tmr_mismatch = (state0 != state1) | (state1 != state2) | (state0 != state2);
endmodule
