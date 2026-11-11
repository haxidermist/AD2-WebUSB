// Digital I/O: the 16 DIO pins, the pattern generator, the DIO test patterns and the cross-trigger routing between
// the capture engine, the waveform generator, the pattern generator and the trigger pins T1/T2.
//
// DIO pins are sampled on both edges of the 100 MHz clock (IDDR2: la_rise, la_fall) and driven through ODDR2s, which
// on Spartan-6 also need an ODDR2 on the tristate path. Output priority: test pattern, then pattern generator, then
// the static levels.
//
// Pattern generator: 2048 x 16 memory (loaded over JTAG USER4), played from address 0 to pg_last at
// 100 MHz / (pg_div + 1), looping or once, on the pins enabled in dio_oe.
//
// Cross-trigger routing (CMD_XTRIG), all in the 100 MHz domain:
//   csrc [2:0]  capture trigger: 0 own condition (scope level / LA pattern), 1 T1, 2 T2, 3 AWG start, 4 PG start,
//               5 DIO pattern/edge (CMD_LA_TRIG) also in scope mode (handled in scope_capture.v)
//   cpol        external trigger edge: 0 rising, 1 falling
//   asrc [2:0]  AWG start / psrc [2:0] PG start: 0 immediately, 1 capture trigger, 2 T1 rising, 3 T2 rising,
//               4 the other generator's start
//   t1o / t2o   T1 / T2 output: 0 input, 1 capture trigger, 2 AWG start (each loop), 3 PG start (each loop);
//               each event gives a 1 us high pulse
`default_nettype none
module dio_pattern (
    input  wire        clk100,
    inout  wire [15:0] dio,
    inout  wire [1:0]  trig,                          // T1, T2
    output wire [15:0] la_rise, output wire [15:0] la_fall,      // samples for the logic analyser
    output wire [15:0] pins,                          // pad levels (for CMD_PINS)
    // static outputs and test patterns
    input  wire [15:0] dio_out, input wire [15:0] dio_oe,
    input  wire        tp_count,                      // counter stepping every half clock (5 ns) on all 16 pins
    input  wire        tp_square,                     // 100 MHz square on all pins (0 in the first half of each clock)
    // pattern generator
    input  wire        pg_run, input wire pg_once, input wire [10:0] pg_last, input wire [23:0] pg_div,
    input  wire        pg_wclk, input wire pg_we, input wire [10:0] pg_waddr, input wire [15:0] pg_wdata,
    // cross-triggering
    input  wire [2:0]  csrc, input wire cpol, input wire [2:0] asrc, input wire [2:0] psrc,
    input  wire [2:0]  t1o, input wire [2:0] t2o,
    input  wire        capev,                         // capture trigger (clk100 pulse)
    input  wire        awg_ev_t,                      // toggles at each AWG start / loop (AWG clock domain)
    output reg         xev = 1'b0,                    // selected external capture trigger (clk100 pulse)
    output reg         awg_start_t = 1'b0             // toggle: start the AWG (when its start source is not 0)
);
    genvar i;

    // trigger pins and events
    wire [1:0]  tpin;
    reg  [1:0]  tq1 = 2'b0, tq2 = 2'b0, tq3 = 2'b0;
    wire        t1r = tq2[0] && !tq3[0], t1f = !tq2[0] && tq3[0], t2r = tq2[1] && !tq3[1], t2f = !tq2[1] && tq3[1];
    reg  [2:0]  aws = 3'b0;
    reg         ev_awg = 1'b0, ev_pg = 1'b0;
    reg  [6:0]  tpc1 = 7'h0, tpc2 = 7'h0;             // T1 / T2 output pulse counters (100 clocks = 1 us)
    always @(posedge clk100) begin
        tq1 <= tpin; tq2 <= tq1; tq3 <= tq2;
        aws <= {aws[1:0], awg_ev_t}; ev_awg <= aws[2] != aws[1];
        case (csrc)
            3'd1: xev <= cpol ? t1f : t1r;  3'd2: xev <= cpol ? t2f : t2r;
            3'd3: xev <= ev_awg;            3'd4: xev <= ev_pg;   default: xev <= 1'b0;
        endcase
        if ((asrc == 3'd1 && capev) || (asrc == 3'd2 && t1r) || (asrc == 3'd3 && t2r) || (asrc == 3'd4 && ev_pg))
            awg_start_t <= ~awg_start_t;
        if ((t1o == 3'd1 && capev) || (t1o == 3'd2 && ev_awg) || (t1o == 3'd3 && ev_pg)) tpc1 <= 7'd100;
        else if (tpc1 != 7'h0) tpc1 <= tpc1 - 7'h1;
        if ((t2o == 3'd1 && capev) || (t2o == 3'd2 && ev_awg) || (t2o == 3'd3 && ev_pg)) tpc2 <= 7'd100;
        else if (tpc2 != 7'h0) tpc2 <= tpc2 - 7'h1;
    end
    IOBUF b_t1 (.IO(trig[0]), .I(tpc1 != 7'h0), .T(t1o == 3'd0), .O(tpin[0]));
    IOBUF b_t2 (.IO(trig[1]), .I(tpc2 != 7'h0), .T(t2o == 3'd0), .O(tpin[1]));

    // test pattern counter (steps by 2 per clock: the falling-edge half shows +1)
    reg  [15:0] pgc = 16'h0;
    always @(posedge clk100) pgc <= pgc + 16'h2;

    // pattern generator
    reg  [15:0] pmem [0:2047];
    always @(posedge pg_wclk) if (pg_we) pmem[pg_waddr] <= pg_wdata;
    reg  [10:0] pga = 11'h0;
    reg  [15:0] pgq = 16'h0, pgo = 16'h0;
    reg  [23:0] pgdc = 24'h0;
    reg  [2:0]  pgs = 3'b0;
    reg         pgact = 1'b0;
    reg         pg_go = 1'b0;                          // started (immediately, or on the psrc event)
    wire        prun = pgs[2] && pg_go;
    wire        pgstb = prun && pgdc == 24'h0;
    wire [10:0] pga_n = !prun ? 11'h0 : !pgstb ? pga : (pga == pg_last) ? (pg_once ? pga : 11'h0) : pga + 11'h1;
    always @(posedge clk100) begin
        pgs <= {pgs[1:0], pg_run};
        if (!pgs[2]) pg_go <= 1'b0;
        else if (psrc == 3'd0 || (psrc == 3'd1 && capev) || (psrc == 3'd2 && t1r) || (psrc == 3'd3 && t2r) || (psrc == 3'd4 && ev_awg))
            pg_go <= 1'b1;
        pgq <= pmem[pga_n];                            // prefetch: pgq always holds the word at pga
        pga <= pga_n;
        pgact <= prun;
        ev_pg <= pgstb && pga == 11'h0;                // word 0 presented: start and every loop
        if (!prun) pgdc <= 24'h0;
        else if (pgstb) begin pgdc <= pg_div; pgo <= pgq; end
        else pgdc <= pgdc - 24'h1;
    end

    // pins
    wire [15:0] dval = pgact ? pgo : dio_out;
    generate for (i = 0; i < 16; i = i + 1) begin : g_dio
        wire oq, tq;
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) o (.Q(oq), .C0(clk100), .C1(~clk100), .CE(1'b1),
            .D0(tp_square ? 1'b0 : tp_count ? pgc[i] : dval[i]),
            .D1(tp_square ? 1'b1 : tp_count ? (pgc[i] ^ (i == 0)) : dval[i]), .R(1'b0), .S(1'b0));
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) t (.Q(tq), .C0(clk100), .C1(~clk100), .CE(1'b1),
            .D0(~(dio_oe[i] | tp_count | tp_square)), .D1(~(dio_oe[i] | tp_count | tp_square)), .R(1'b0), .S(1'b0));
        IOBUF b (.IO(dio[i]), .I(oq), .T(tq), .O(pins[i]));
        IDDR2 #(.DDR_ALIGNMENT("C0"), .INIT_Q0(1'b0), .INIT_Q1(1'b0), .SRTYPE("SYNC")) r (
            .Q0(la_rise[i]), .Q1(la_fall[i]), .C0(clk100), .C1(~clk100), .CE(1'b1), .D(pins[i]), .R(1'b0), .S(1'b0));
    end endgenerate
endmodule
`default_nettype wire
