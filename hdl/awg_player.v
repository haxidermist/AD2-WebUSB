// Waveform generator: plays an 8192-word memory into the AD9717 dual DAC.
//
// The AD9717 runs in single-port interleaved mode: both channels share the 14-bit data bus, driven by ODDR2s from a
// DCM copy of the 100 MHz ADC clock (CLK0), with channel A in the first (high) half of each clock unless swapped. The
// DCLKIO clock comes from CLK90 so its edges sit in the middle of the data eye.
//
// Memory words are {B[13:0], A[13:0]}, two's complement, loaded over JTAG USER4. Playback either steps through
// addresses 0..last (one word per clock), or, with the DDS on, uses the phase accumulator: f = ftw * 100 MHz / 2^32
// and address = phase[31:19], so the memory holds one period of the waveform.
//
// Config (CMD_AWG): acfg[2] play, [3] invert DCLKIO, [4] swap A/B, [5] DCM reset (acfg[1], memory load, is used by
// the loader in the top level). Playback starts immediately, or on the start toggle when asrc != 0.
`default_nettype none
module awg_player (
    input  wire        clk12,
    input  wire        clk_in,                        // 100 MHz ADC clock (after the IBUFG)
    input  wire [5:2]  acfg,
    input  wire [12:0] last,                          // last address of address playback
    input  wire [31:0] ftw_t, input wire dds_t, input wire ftw_tog,   // DDS word and on/off, applied on each toggle
    input  wire [2:0]  asrc,                          // start source (0 = immediately)
    input  wire        start_t,                       // start toggle from the cross-trigger logic
    input  wire        mem_wclk, input wire mem_we, input wire [12:0] mem_waddr, input wire [27:0] mem_wdata,
    output wire [13:0] dac_d, output wire dac_clk,
    output wire        locked,                        // DCM lock (status bit)
    output reg         ev_t = 1'b0                    // toggles at each start / loop (DDS: each phase wrap)
);
    genvar i;

    // clocks: DCM copy of the ADC clock, held in reset while acfg[5] is set
    wire c0, c90, clk, clk90;
    reg  [2:0] rst_s = 3'b0;
    always @(posedge clk12) rst_s <= {rst_s[1:0], acfg[5]};
    DCM_SP #(.CLKIN_PERIOD(10.0), .CLK_FEEDBACK("1X"), .CLKOUT_PHASE_SHIFT("NONE"), .DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"))
        dcm (.CLKIN(clk_in), .CLKFB(clk), .RST(rst_s[2]), .CLK0(c0), .CLK90(c90), .LOCKED(locked),
             .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(), .CLKDV(), .CLKFX(), .CLKFX180(), .STATUS(),
             .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(), .DSSEN(1'b0));
    BUFG b_clk (.I(c0), .O(clk));
    BUFG b_clk90 (.I(c90), .O(clk90));

    reg  [27:0] amem [0:8191];
    always @(posedge mem_wclk) if (mem_we) amem[mem_waddr] <= mem_wdata;

    reg  [2:0]  ps = 3'b0, ats = 3'b0, fts = 3'b0;     // synchronisers: play, start toggle, DDS word toggle
    reg  [2:0]  asrc_a = 3'd0;
    reg         ago = 1'b0, ago_d = 1'b0;              // playing
    reg  [12:0] pa = 13'h0;                            // playback address
    reg  [27:0] aq = 28'h0;
    reg  [13:0] h0 = 14'h0, h1 = 14'h0;               // first / second half of the clock
    reg  [31:0] ftw = 32'h0, dph = 32'h0;
    reg         dds = 1'b0;
    wire [32:0] phs = {1'b0, dph} + {1'b0, ftw};
    always @(posedge clk) begin
        ps <= {ps[1:0], acfg[2]}; ats <= {ats[1:0], start_t}; asrc_a <= asrc; ago_d <= ago;
        if (!ps[2]) ago <= 1'b0; else if (asrc_a == 3'd0 || ats[2] != ats[1]) ago <= 1'b1;
        fts <= {fts[1:0], ftw_tog}; if (fts[2] != fts[1]) begin ftw <= ftw_t; dds <= dds_t; end
        if (!ago) dph <= 32'h0; else dph <= phs[31:0];
        if (ago && (!ago_d || (dds ? phs[32] : pa == last))) ev_t <= ~ev_t;
        aq <= amem[dds ? dph[31:19] : pa];
        if (!ago) pa <= 13'h0; else pa <= (pa == last) ? 13'h0 : pa + 13'h1;
        h0 <= !ago ? 14'h0 : acfg[4] ? aq[27:14] : aq[13:0];
        h1 <= !ago ? 14'h0 : acfg[4] ? aq[13:0] : aq[27:14];
    end
    generate for (i = 0; i < 14; i = i + 1) begin : g_dac
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) o (.Q(dac_d[i]), .C0(clk), .C1(~clk), .CE(1'b1),
            .D0(h0[i]), .D1(h1[i]), .R(1'b0), .S(1'b0));
    end endgenerate
    ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) o_clk (.Q(dac_clk), .C0(clk90), .C1(~clk90), .CE(1'b1),
        .D0(~acfg[3]), .D1(acfg[3]), .R(1'b0), .S(1'b0));
endmodule
`default_nettype wire
