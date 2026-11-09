// ADF4360-9 clock synthesiser register writer, controlled through JTAG USER1.
//
// USER1 data register (40 bits):
//   update with bit 36 set: write bits [23:0] to the ADF4360 (one 24-bit register word, MSB first)
//   capture: {SIG_STATUS, 15'b0, busy, 15'b0, lock_detect}
// The word is shifted out in the 12 MHz domain at 12 MHz / 16 = 750 kHz: LE low, 24 x (data, CLK high), LE high.
`default_nettype none
module adf4360_spi (
    input  wire clk12,
    // JTAG USER1
    input  wire tck, input wire sel, input wire capture, input wire shift, input wire update, input wire tdi,
    output wire tdo,
    input  wire lock_detect,                          // ADF4360 MUXOUT / LD (M13)
    output wire le, output wire sclk, output wire sdata
);
    `include "ad2_defs.vh"

    // JTAG side
    reg  [39:0] sr = 40'h0;
    reg  [23:0] word_t = 24'h0;                       // word to send (TCK domain)
    reg         req = 1'b0;                           // toggles once per write request
    reg         busy = 1'b0;
    always @(posedge tck) begin
        if (sel && capture) sr <= {SIG_STATUS, 15'h0, busy, 15'h0, lock_detect};
        else if (sel && shift) sr <= {tdi, sr[39:1]};
        if (sel && update && sr[36]) begin word_t <= sr[23:0]; req <= ~req; end
    end
    assign tdo = sr[0];

    // 12 MHz side: step every 8 clocks; step 1 = LE low, steps 2..49 = 24 bits as (CLK low + data, CLK high), then LE high
    reg  [2:0]  req_s = 3'b0, div = 3'b0;
    reg  [23:0] w = 24'h0;
    reg  [5:0]  step = 6'h0;
    reg         le_r = 1'b1, ck_r = 1'b0, d_r = 1'b0;
    always @(posedge clk12) begin
        req_s <= {req_s[1:0], req};
        div <= div + 3'b1;
        if (req_s[2] != req_s[1]) begin w <= word_t; busy <= 1'b1; step <= 6'h1; end
        else if (busy && div == 3'b0) begin
            if (step == 6'h1) begin le_r <= 1'b0; ck_r <= 1'b0; step <= 6'h2; end
            else if (step < 6'd50) begin
                if (!step[0]) begin ck_r <= 1'b0; d_r <= w[23 - (step[5:1] - 5'd1)]; end
                else ck_r <= 1'b1;
                step <= step + 6'h1;
            end else begin ck_r <= 1'b0; d_r <= 1'b0; le_r <= 1'b1; busy <= 1'b0; step <= 6'h0; end
        end
    end
    assign le = le_r; assign sclk = ck_r; assign sdata = d_r;
endmodule
`default_nettype wire
