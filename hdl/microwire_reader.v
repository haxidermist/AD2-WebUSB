// Calibration EEPROM reader: IC37, a 93LC66B (x16 organisation) on a Microwire bus. READ only.
//
// Each toggle of `start` reads the 16-bit word at `addr`. The sequence runs in the 12 MHz domain with one step per
// 8 clocks (667 ns):
//   step 0-1   CS low, then high
//   step 2-34  start bit 1, opcode 10, address A7..A0; three steps per bit (CLK low, high, low)
//   step 35    DI/DO released
//   step 36-69 CLK high on even steps (DO sampled at the end of the step), low on odd steps; the first sample is D15
//              (the device's dummy 0 comes with the last address clock)
//   step 70    CS low, done
// CLK is the control-port pin P3: while `busy` is high the top level hands that pin to `ee_clk`.
// WaveForms stores its calibration table low byte first in each word.
`default_nettype none
module microwire_reader (
    input  wire        clk12,
    input  wire        start,                         // toggle: read one word
    input  wire [7:0]  addr,
    output wire        busy,
    output wire [15:0] data,                          // last word read
    output wire        ee_cs, output wire ee_clk,
    inout  wire        ee_dio                         // shared DI/DO (P4)
);
    reg  [2:0]  start_s = 3'b0, sub = 3'b0;
    reg  [6:0]  step = 7'h0;
    reg  [1:0]  phase = 2'b0;                          // step within a command bit
    reg  [10:0] cmd = 11'h0;
    reg         run = 1'b0, cs_r = 1'b0, ck_r = 1'b0, do_r = 1'b0, oe_r = 1'b0;
    reg  [15:0] dr = 16'h0;
    wire        din;
    IOBUF b_dio (.IO(ee_dio), .I(do_r), .T(~oe_r), .O(din));
    always @(posedge clk12) begin
        start_s <= {start_s[1:0], start};
        if (!run) begin
            cs_r <= 1'b0; ck_r <= 1'b0; oe_r <= 1'b0;
            if (start_s[2] != start_s[1]) begin run <= 1'b1; step <= 7'h0; sub <= 3'h0; phase <= 2'h0; cmd <= {3'b110, addr}; end
        end else begin
            sub <= sub + 3'h1;
            cs_r <= (step >= 7'd1 && step <= 7'd69);
            oe_r <= (step <= 7'd34); do_r <= (step >= 7'd2 && step <= 7'd34) && cmd[10];
            ck_r <= (step >= 7'd2 && step <= 7'd34) ? (phase == 2'd1) : (step >= 7'd36 && step <= 7'd69) ? ~step[0] : 1'b0;
            if (sub == 3'h7) begin
                step <= step + 7'h1;
                if (step >= 7'd2 && step <= 7'd34) begin
                    if (phase == 2'd2) begin phase <= 2'd0; cmd <= {cmd[9:0], 1'b0}; end else phase <= phase + 2'd1;
                end
                if (step >= 7'd36 && step <= 7'd66 && !step[0]) dr <= {dr[14:0], din};
                if (step == 7'd70) run <= 1'b0;
            end
        end
    end
    assign busy = run; assign data = dr; assign ee_cs = cs_r; assign ee_clk = ck_r;
endmodule
`default_nettype wire
