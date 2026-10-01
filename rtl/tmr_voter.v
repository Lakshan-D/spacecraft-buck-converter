// Bitwise 2-of-3 majority voter for triple modular redundancy (TMR).
// A single flipped bit in any one of a, b, c is out-voted by the other two.
module tmr_voter #(
    parameter W = 8
) (
    input  [W-1:0] a,
    input  [W-1:0] b,
    input  [W-1:0] c,
    output [W-1:0] y
);
    assign y = (a & b) | (b & c) | (a & c);
endmodule
