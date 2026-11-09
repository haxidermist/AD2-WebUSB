// Capture engine: oscilloscope and logic analyser share one 8192 x 32-bit memory, written in the 100 MHz sample clock
// domain and read by the USB FIFO reader in its own clock domain.
//
// Memory words
//   scope:     {gap, 1'b0, fall[13:0] (CH2), 2'b0, rise[13:0] (CH1)}; ADC samples are offset binary, CH1 is the sample
//              taken on the rising edge of the ADC clock and CH2 the one on the falling edge (interleaved CMOS bus)
//   min/max:   pairs of words per interval, min first, then max with bit 31 set
//   average:   {CH2 mean, CH1 mean}, 16 bits each with 2 fraction bits (all 32 bits used)
//   LA:        two 16-bit samples per word {newer, older}; at 200 MS/s {falling-edge, rising-edge} sample of one clock
//   gap (bit 30, continuous mode only): samples were dropped just before this word because the reader fell behind
//
// Sequence (snapshot): arm -> PRE (store `pre` samples) -> WAIT (circular, until trigger or force) -> POST (the trigger
// sample plus 8191 - pre more) -> done; `tpos` = address of the trigger sample, so time order starts at tpos - pre.
// Continuous mode (`cont`): the writer runs as a ring behind the USB reader until stopped.
//
// Sampling: one stored sample every dec + 1 clocks (decimation). Mode 1 averages 2^avk raw samples per stored sample
// (avk 2..16), mode 2 stores the min and max of each interval (needs dec >= 1). The trigger runs at the full 100 MS/s on
// CH1 or CH2 (level crossing with hysteresis), on an LA pattern (with optional edge), or on a cross-trigger event.
`default_nettype none
module scope_capture (
    input  wire        clk100,
    input  wire [13:0] adc_rise, input wire [13:0] adc_fall,     // ADC samples (IDDR2 outputs)
    input  wire [15:0] la_rise,  input wire [15:0] la_fall,      // DIO samples (IDDR2 outputs)
    // configuration (written by the command decoder; static while a capture runs)
    input  wire [23:0] dec,                           // samples skipped between stored samples
    input  wire [12:0] pre,                           // stored samples before the trigger
    input  wire        cont,                          // continuous ring-buffer streaming
    input  wire        la, input wire la200,          // logic-analyser mode, LA at 200 MS/s (both clock edges)
    input  wire [1:0]  smode,                         // 0 decimate, 1 average, 2 min/max
    input  wire [4:0]  avk,                           // averaging over 2^avk samples
    input  wire [13:0] lvl, input wire [13:0] tlo, input wire [13:0] thi,   // trigger level and hysteresis band
    input  wire        tsrc, input wire tslope, input wire ten,             // CH2 source, falling slope, trigger on
    input  wire [15:0] lmask, input wire [15:0] lval,                       // LA trigger pattern
    input  wire [3:0]  lch, input wire ledge, input wire lpol,              // LA edge channel, edge on, falling edge
    input  wire        ext_trig,                      // use the cross-trigger event instead of the own condition
    input  wire        xev,                           // cross-trigger event (clk100 pulse)
    // control toggles (any clock domain)
    input  wire        arm_t, input wire force_t, input wire stop_t,
    // status
    output reg         run = 1'b0, output reg done = 1'b0, output reg trg = 1'b0,   // trg: triggered (not forced)
    output reg         tph = 1'b0,                    // LA: the trigger sample is the second half of its word
    output reg  [1:0]  stg = 2'd0,                    // 0 PRE, 1 WAIT, 2 POST, 3 continuous
    output reg  [12:0] tpos = 13'h0,
    output reg         capev = 1'b0,                  // pulse: own trigger condition met (for cross-triggering)
    output reg         done_t = 1'b0,                 // toggles when a snapshot is complete
    output reg         cont_t = 1'b0,                 // toggles when continuous streaming starts
    output wire        avg,                           // average words in memory
    // memory read port and ring-buffer handshake with the USB reader
    input  wire        rd_clk, input wire [12:0] rd_addr, output reg [31:0] rd_data = 32'h0,
    input  wire [12:0] rd_addr_gray,                  // reader address, Gray coded, rd_clk domain
    output reg  [12:0] wr_addr_gray = 13'h0           // writer address, Gray coded, clk100 domain
);
    `include "ad2_defs.vh"

    reg [31:0] mem [0:8191];
    always @(posedge rd_clk) rd_data <= mem[rd_addr];

    // LA trigger condition for sample s with previous sample p
    function lhit;
        input [15:0] s, p;
        lhit = (((s ^ lval) & lmask) == 16'h0) && (!ledge || (lpol ? (p[lch] && !s[lch]) : (!p[lch] && s[lch])));
    endfunction

    // reader position (for the continuous ring)
    reg  [12:0] ra_g1 = 13'h0, ra_g2 = 13'h0;
    wire [12:0] ra = gray2bin(ra_g2);
    reg  [12:0] wa = 13'h0;                           // write address
    wire        full = (stg == 2'd3) && (wa + 13'h1 == ra);   // ring full: drop this sample, flag the gap in the next word
    reg         gapf = 1'b0, wgap = 1'b0;

    reg  [2:0]  as = 3'b0, fs = 3'b0, ss = 3'b0;       // synchronisers of the arm / force / stop toggles
    reg  [13:0] cnt = 14'h0;                           // samples left in PRE / POST
    reg  [23:0] dc = 24'h0;                            // decimation counter
    reg         stb = 1'b0;                            // store this sample (registered: dc == 0, computed a cycle early)

    // trigger detectors
    reg  [13:0] tx = 14'h0;
    reg         tarm = 1'b0, tev = 1'b0, tpend = 1'b0, tfo = 1'b0;   // armed past the hysteresis, event, pending, forced
    reg  [15:0] lx0 = 16'h0, lx1 = 16'h0, lxp = 16'h0;
    reg         lev = 1'b0, lev1 = 1'b0, llo = 1'b0, llo1 = 1'b0;   // LA trigger match, delayed to align with the data
    reg         half = 1'b0, tseen = 1'b0;             // packed LA: which half of the word, trigger sample placed
    reg  [15:0] lhold = 16'h0;

    // data pipeline (3 cycles, matching the trigger latency) and write port
    reg  [31:0] d1 = 32'h0, d2 = 32'h0, d3 = 32'h0, wd = 32'h0, wdA = 32'h0;
    reg         we = 1'b0, we_d = 1'b0;
    reg  [12:0] wad = 13'h0, wad_d = 13'h0;

    // min/max and average accumulators
    assign avg = !la && smode == 2'd1;
    wire        mm = !la && smode == 2'd2;
    reg         stb_d = 1'b0;
    wire        wstb = mm ? (stb || stb_d) : stb && (!la || la200 || half);   // LA below 200 MS/s packs two samples per word
    reg  [29:0] acc1 = 30'h0, acc2 = 30'h0, accf1 = 30'h0, accf2 = 30'h0;
    reg  [13:0] mn1 = 14'h3fff, mn2 = 14'h3fff, mx1 = 14'h0, mx2 = 14'h0, mxl1 = 14'h0, mxl2 = 14'h0;
    wire [13:0] s1 = d3[13:0], s2 = d3[29:16];
    wire [13:0] mnf1 = s1 < mn1 ? s1 : mn1, mnf2 = s2 < mn2 ? s2 : mn2, mxf1 = s1 > mx1 ? s1 : mx1, mxf2 = s2 > mx2 ? s2 : mx2;
    wire [4:0]  ash = avk - 5'd2;
    wire [29:0] mean1 = accf1 >> ash, mean2 = accf2 >> ash;   // x 4: two fraction bits

    always @(posedge clk100) begin
        as <= {as[1:0], arm_t}; fs <= {fs[1:0], force_t}; ss <= {ss[1:0], stop_t}; capev <= 1'b0;
        ra_g1 <= rd_addr_gray; ra_g2 <= ra_g1; wr_addr_gray <= wa ^ (wa >> 1);

        // trigger detectors at the full rate
        tx <= tsrc ? adc_fall : adc_rise;
        lx0 <= la_rise; lx1 <= la_fall; lxp <= la200 ? lx1 : lx0;
        lev <= run && (lhit(lx0, lxp) || (la200 && lhit(lx1, lx0)));
        lev1 <= lev;
        llo <= run && lhit(lx0, lxp); llo1 <= llo;   // 200 MS/s: did the rising-edge sample match?
        if (!run) begin tarm <= 1'b0; tev <= 1'b0; end
        else if (!tslope) begin if (tx < tlo) tarm <= 1'b1; tev <= tarm && tx >= lvl; if (tarm && tx >= lvl) tarm <= 1'b0; end
        else begin if (tx > thi) tarm <= 1'b1; tev <= tarm && tx <= lvl; if (tarm && tx <= lvl) tarm <= 1'b0; end

        // storage pipeline; LA words: 200 MS/s {falling, rising} sample of each clock, else {new, held older} samples
        d1 <= !la ? {2'b0, adc_fall, 2'b0, adc_rise} : la200 ? {lx1, lx0} : {lx0, 16'h0}; d2 <= d1; d3 <= d2;
        wd <= (la && !la200) ? {d3[31:16], lhold} : d3;
        if (mm) wd <= stb ? {2'b00, mnf2, 2'b00, mnf1} : {2'b10, mxl2, 2'b00, mxl1};   // min word, then max word

        // min/max and average accumulate every raw sample (d3, aligned with the trigger); the strobe closes an interval
        stb_d <= run && stb;
        if (!run || stb) begin
            mn1 <= 14'h3fff; mn2 <= 14'h3fff; mx1 <= 14'h0; mx2 <= 14'h0; acc1 <= 30'h0; acc2 <= 30'h0;
            if (stb) begin mxl1 <= mxf1; mxl2 <= mxf2; accf1 <= acc1 + s1; accf2 <= acc2 + s2; end
        end else begin
            mn1 <= mnf1; mn2 <= mnf2; mx1 <= mxf1; mx2 <= mxf2; acc1 <= acc1 + s1; acc2 <= acc2 + s2;
        end
        wdA <= {mean2[15:0], mean1[15:0]};

        // memory write (averages one cycle later than the other modes)
        we_d <= we; wad_d <= wad;
        wad <= wa; we <= run && wstb && !full; wgap <= gapf;
        if (avg ? we_d : we) mem[avg ? wad_d : wad] <= avg ? wdA : la ? wd : (mm ? {wd[31], wgap, wd[29:0]} : {1'b0, wgap, wd[29:0]});
        if (stb && la && !la200) begin half <= ~half; lhold <= d3[31:16]; end

        // sequencer
        if (as[2] != as[1]) begin                      // arm
            run <= 1'b1; done <= 1'b0; trg <= 1'b0; wa <= 13'h0; dc <= 24'h0; stb <= 1'b1; tpend <= 1'b0; gapf <= 1'b0;
            half <= 1'b0; tseen <= 1'b0;
            if (cont) begin stg <= 2'd3; cont_t <= ~cont_t; end
            else if (pre == 13'h0) begin stg <= 2'd1; cnt <= 14'h0; end else begin stg <= 2'd0; cnt <= {1'b0, pre}; end
        end else if (ss[2] != ss[1]) begin             // stop
            run <= 1'b0;
        end else if (run) begin
            dc <= stb ? dec : dc - 24'h1;
            stb <= stb ? (dec == 24'h0) : (dc == 24'h1);
            if (stg == 2'd1 && !tpend) begin
                if (ten && (ext_trig ? xev : la ? lev1 : tev)) begin tpend <= 1'b1; tfo <= 1'b0; capev <= 1'b1; if (la200) tph <= !llo1; end
                else if (fs[2] != fs[1] || !ten) begin tpend <= 1'b1; tfo <= 1'b1; end
            end
            // packed LA: the first stored sample after the trigger is the older half of a word if it arrives on a
            // strobe that does not write
            if (stb && la && !la200 && stg == 2'd1 && tpend && !tseen) begin tseen <= 1'b1; tph <= half; end
            if (wstb) begin
                if (stg != 2'd3) wa <= wa + 13'h1;
                case (stg)
                2'd0: begin cnt <= cnt - 14'h1; if (cnt == 14'h1) stg <= 2'd1; end
                2'd1: if (tpend) begin                 // this sample is the trigger sample; 8191 - pre more follow
                    tpos <= wa; trg <= !tfo; stg <= 2'd2; cnt <= 14'd8191 - {1'b0, pre};
                    if (pre == 13'h1fff) begin run <= 1'b0; done <= 1'b1; done_t <= ~done_t; end
                end
                2'd2: begin if (cnt == 14'h1) begin run <= 1'b0; done <= 1'b1; done_t <= ~done_t; end cnt <= cnt - 14'h1; end
                default: if (full) gapf <= 1'b1; else begin wa <= wa + 13'h1; gapf <= 1'b0; end   // continuous
                endcase
            end
        end
    end
endmodule
`default_nettype wire
