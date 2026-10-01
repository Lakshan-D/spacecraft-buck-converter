// Behavioural plant for simulation only (uses real numbers, not synthesisable).
// Synchronous buck, switching-level model, forced CCM:
//   L diL/dt = vsw - vc - Rp*iL ;  C dvc/dt = iL - vc/Rload
// Semi-implicit Euler (update iL, then vc with the new iL) so the LC loop does not
// gain or lose energy numerically. Updates on the falling clock edge so the RTL,
// which samples on the rising edge, never races with it.
// Real values cross the port as 64-bit vectors ($realtobits) for tool portability.
`timescale 1ns/1ps
module buck_plant #(
    parameter real L  = 22e-6,
    parameter real C  = 47e-6,
    parameter real RP = 0.1,
    parameter real DT = 10e-9
) (
    input         clk,
    input         pwm,
    input  [63:0] vin_b,
    input  [63:0] rload_b,
    output reg [11:0] adc,
    output [63:0] vo_b,
    output [63:0] il_b
);
    real il, vc, vsw, vin, rload, code;

    initial begin il = 0.0; vc = 0.0; adc = 12'd0; end

    assign vo_b = $realtobits(vc);
    assign il_b = $realtobits(il);

    always @(negedge clk) begin
        vin   = $bitstoreal(vin_b);
        rload = $bitstoreal(rload_b);
        vsw   = pwm ? vin : 0.0;
        il    = il + DT * (vsw - vc - RP * il) / L;
        vc    = vc + DT * (il - vc / rload) / C;
        code  = vc * 512.0 + 0.5;                 // 12-bit ADC, 8 V full-scale
        if (code < 0.0)         adc <= 12'd0;
        else if (code > 4095.0) adc <= 12'd4095;
        else                    adc <= $rtoi(code);
    end
endmodule
