// One copy of the TMR-protected controller state.
// Synthesis tools see three registers that always load the same value and merge
// them into one, which silently removes the redundancy (yosys does this: the
// design dropped from 210 to 70 state flip-flops). keep_hierarchy stops that:
// each copy is its own instance that the optimiser may not merge across, the
// same job DONT_TOUCH / syn_preserve do in vendor tools.
(* keep_hierarchy *)
module tmr_copy #(
    parameter W = 70
) (
    input              clk,
    input              rst,
    input              en,
    input      [W-1:0] d,
    output reg [W-1:0] q
);
    always @(posedge clk) begin
        if (rst)     q <= {W{1'b0}};
        else if (en) q <= d;
    end
endmodule
