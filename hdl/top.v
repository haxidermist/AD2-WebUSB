// AD2 scope + AWG: ADF4360 writer (USER1, as pllclk), control/status (USER2), 32-pin control port (USER3),
// 8192-sample scope BRAM readout and AWG BRAM load (USER4).
// ADC bus (CMOS interleaved on port B) is taken with IDDR2 on both CLKOUT (H12) edges; one BRAM word per cycle =
// {2'b0, fall[13:0], 2'b0, rise[13:0]}.
// AWG: AD9717 single-port interleaved bus driven by ODDR2 from a DCM copy of H12 (CLK0); the DCLKIO clock on C8 comes
// from CLK90 so its edges sit mid-eye. Playback memory 8192 x {2'b0, B[13:0], 2'b0, A[13:0]} (two's complement),
// A on the first (high) half of each cycle unless swapped.
// USER2 DR (56 bits): update with [55:48] = 8'h5A and [0] = 1 toggles arm; with [55:48] = 8'h5B sets the AWG config
//   [1] load enable, [2] play, [3] invert DCLKIO, [4] swap A/B halves, [5] DCM reset, [28:16] last playback address;
//   [1] = 1 forces a trigger; 5D sets dec [23:0] and pre [36:24]; 5E sets level [13:0], hysteresis [27:14], source [28]
//   (0 CH1, 1 CH2), slope [29] (0 rising), trigger enable [30]; 5C sets the gain switches;
//   capture {8'hA5, 5'b0, dcm_locked, ld, done, run, stage[1:0], tpos[12:0], 7'b0, khz[16:0]} (khz = H12 cycles per 1 ms of P7).
// USER3 DR (64 bits): [31:0] out, [63:32] oe; capture {oe, pins}. Reset = WaveForms idle levels.
// USER4 DR: capture loads a 32-bit header {8'hA5, triggered, 10'b0, tpos[12:0]}, then shifting streams mem[0], mem[1], ... LSB first;
//   with load enable, every 32 shifted-in bits are written to the AWG memory at 8191, 0, 1, ... (first word is a dummy).
module top(
    output [8:0] st,
    output le, output sck, output sdo,
    inout  [24:0] pp,                                 // pads of control-port bits 0-31 except 4 5 6 9 10 12 (USB FIFO) and 26 (DIO0)
    inout  [15:0] dio,                                // DIO0..15 = D1 D2 F2 G1 J1 J2 H1 H2 G2 F1 M1 M2 L1 L2 K1 K2
    inout  [1:0] tp,                                  // trigger pins T1 = E2, T2 = E1
    input  clk60, input rxf_n, input txe_n,           // FT232H sync FIFO: CLKOUT N8, RXF# N11, TXE# P11
    output rd_n, output wr_n, output oe_n,            // RD# N10, WR# P10, OE# P8
    inout  [6:0] ud,                                  // D0 N13 (= JTAG TCK, held low), D1 P13, D3 P12, D4 L8, D5 N9, D6 M8, D7 N7
    output siwu,                                      // P9, held high
    output [13:0] da, output dclk,
    input  [13:0] ad,
    input  p7, input h12, input ld,
    output mw_cs, inout mw_dio                        // IC37 calibration EEPROM (93LC66B): CS N2, shared DI/DO P4; CLK = P3 (port bit 7)
);
    reg [3:0] gsw = 4'b0101;                            // scope gain switches {J4 EN_HG_SC1, F3 EN_LG_SC1, C1 EN_HG_SC2, B1 EN_LG_SC2}; USER2 sig 5C sets [3:0]
    reg [1:0] usr = 2'b00;                             // user supplies: {P2, N5} = converter enables (sig 66; WaveForms raises both together)
    assign st = {usr[1], usr[0], 2'b11, gsw[3], 1'b1, gsw[2], gsw[1], gsw[0]};

    wire tck_raw, tck, tdi, capture, shift, update, sel1, sel2, sel3, sel4, tdo1, tdo2, tdo3, tdo4;
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(1)) bs1 (.CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel1),
        .SHIFT(shift), .TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo1));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(2)) bs2 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel2),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo2));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(3)) bs3 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel3),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo3));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(4)) bs4 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel4),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo4));
    BUFG btck (.I(tck_raw), .O(tck));                // global TCK: local routing broke the longer chains

    wire g0, gd, h12b;
    BUFG bg0 (.I(p7), .O(g0));
    IBUFG ibd (.I(h12), .O(h12b));
    BUFG bgd (.I(h12b), .O(gd));

    // ADC bus: IDDR2, Q0 = rising-edge sample, Q1 = falling-edge sample, both aligned to the rising edge
    wire [13:0] qr, qf;
    genvar i;
    generate for (i = 0; i < 14; i = i + 1) begin : dd
        IDDR2 #(.DDR_ALIGNMENT("C0"), .INIT_Q0(1'b0), .INIT_Q1(1'b0), .SRTYPE("SYNC")) r (
            .Q0(qr[i]), .Q1(qf[i]), .C0(gd), .C1(~gd), .CE(1'b1), .D(ad[i]), .R(1'b0), .S(1'b0));
    end endgenerate

    // ---- digital I/O: IDDR2 sampling on both gd edges (l0 = rising-edge sample, l1 = falling), ODDR2 outputs ----
    // Static outputs dout/doe (USER2 sig 60); test pattern (sig 63): a 16-bit counter stepping every half clock (5 ns).
    reg [15:0] dvo = 16'h0, dvoe = 16'h0;
    reg pg_en = 1'b0, pg_sq = 1'b0;                    // sig 63: [0] counter pattern, [1] 100 MHz square (0 first half, 1 second)
    wire [15:0] l0, l1, dpad;
    reg [15:0] pgc = 16'h0;
    always @(posedge gd) pgc <= pgc + 16'h2;
    // ---- cross-triggering (USER2 sig 67), gd domain ----
    // [2:0] capture source: 0 own condition (scope level / LA pattern), 1 T1, 2 T2, 3 AWG start, 4 pattern-generator start;
    // [3] external edge: 0 rising, 1 falling. [6:4] AWG start / [10:8] PG start: 0 immediately, 1 capture trigger,
    // 2 T1 rising, 3 T2 rising, 4 the other generator's start. [14:12] T1 / [18:16] T2 output: 0 input, 1 capture
    // trigger, 2 AWG start (each loop), 3 PG start (each loop); a 1 us high pulse.
    reg [2:0] csrc = 3'd0, asrc = 3'd0, psrc = 3'd0, t1o = 3'd0, t2o = 3'd0;
    reg cpol = 1'b0;
    wire [1:0] tpin;
    reg [1:0] tq1 = 2'b0, tq2 = 2'b0, tq3 = 2'b0;
    reg capev = 1'b0, ev_awg = 1'b0, ev_pg = 1'b0;
    reg [2:0] aws = 3'b0;
    reg awt = 1'b0, atog = 1'b0;
    reg [6:0] tpc1 = 7'h0, tpc2 = 7'h0;
    wire t1r = tq2[0] && !tq3[0], t1f = !tq2[0] && tq3[0], t2r = tq2[1] && !tq3[1], t2f = !tq2[1] && tq3[1];
    reg xev = 1'b0;
    always @(posedge gd) begin
        tq1 <= tpin; tq2 <= tq1; tq3 <= tq2;
        aws <= {aws[1:0], awt}; ev_awg <= aws[2] != aws[1];
        case (csrc)
            3'd1: xev <= cpol ? t1f : t1r;  3'd2: xev <= cpol ? t2f : t2r;
            3'd3: xev <= ev_awg;            3'd4: xev <= ev_pg;   default: xev <= 1'b0;
        endcase
        if ((asrc == 3'd1 && capev) || (asrc == 3'd2 && t1r) || (asrc == 3'd3 && t2r) || (asrc == 3'd4 && ev_pg)) atog <= ~atog;
        if ((t1o == 3'd1 && capev) || (t1o == 3'd2 && ev_awg) || (t1o == 3'd3 && ev_pg)) tpc1 <= 7'd100; else if (tpc1 != 7'h0) tpc1 <= tpc1 - 7'h1;
        if ((t2o == 3'd1 && capev) || (t2o == 3'd2 && ev_awg) || (t2o == 3'd3 && ev_pg)) tpc2 <= 7'd100; else if (tpc2 != 7'h0) tpc2 <= tpc2 - 7'h1;
    end
    IOBUF btp1 (.IO(tp[0]), .I(tpc1 != 7'h0), .T(t1o == 3'd0), .O(tpin[0]));
    IOBUF btp2 (.IO(tp[1]), .I(tpc2 != 7'h0), .T(t2o == 3'd0), .O(tpin[1]));

    // pattern generator: 2048 x 16 memory loaded over USER4 (sig 64 [1] load), played at 100 MHz / (pgdiv + 1) from
    // address 0 to pglast, looping or once (sig 64: [0] run, [2] once, [26:16] last; sig 65: [23:0] div). Pins: dvoe.
    reg pgrun = 1'b0, pgload = 1'b0, pgonce = 1'b0;
    reg [10:0] pglast = 11'h0;
    reg [23:0] pgdiv = 24'h0, pgdc = 24'h0;
    reg [15:0] pmem [0:2047];
    reg [10:0] pga = 11'h0;
    reg [15:0] pgq = 16'h0, pgo = 16'h0;
    reg [2:0] pgs = 3'b0;
    reg pgact = 1'b0;
    reg pgo_go = 1'b0;                                 // started (immediately, or on the psrc event)
    wire prun = pgs[2] && pgo_go;
    wire pgstb = prun && pgdc == 24'h0;
    wire [10:0] pga_n = !prun ? 11'h0 : !pgstb ? pga : (pga == pglast) ? (pgonce ? pga : 11'h0) : pga + 11'h1;
    always @(posedge gd) begin
        pgs <= {pgs[1:0], pgrun};
        if (!pgs[2]) pgo_go <= 1'b0;
        else if (psrc == 3'd0 || (psrc == 3'd1 && capev) || (psrc == 3'd2 && t1r) || (psrc == 3'd3 && t2r) || (psrc == 3'd4 && ev_awg)) pgo_go <= 1'b1;
        pgq <= pmem[pga_n];                            // prefetch: pgq always holds the word at pga
        pga <= pga_n;
        pgact <= prun;
        ev_pg <= pgstb && pga == 11'h0;                // word 0 presented: start and every loop
        if (!prun) pgdc <= 24'h0;
        else if (pgstb) begin pgdc <= pgdiv; pgo <= pgq; end
        else pgdc <= pgdc - 24'h1;
    end
    wire [15:0] dval = pgact ? pgo : dvo;
    generate for (i = 0; i < 16; i = i + 1) begin : dg
        wire oq;
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) o (.Q(oq), .C0(gd), .C1(~gd), .CE(1'b1),
            .D0(pg_sq ? 1'b0 : pg_en ? pgc[i] : dval[i]), .D1(pg_sq ? 1'b1 : pg_en ? (pgc[i] ^ (i == 0)) : dval[i]), .R(1'b0), .S(1'b0));   // D1 = counter + 1; square: 0 then 1
        wire tq;                                       // Spartan-6: an ODDR2 data path needs an ODDR2 tristate path too
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) t (.Q(tq), .C0(gd), .C1(~gd), .CE(1'b1),
            .D0(~(dvoe[i] | pg_en | pg_sq)), .D1(~(dvoe[i] | pg_en | pg_sq)), .R(1'b0), .S(1'b0));
        IOBUF b (.IO(dio[i]), .I(oq), .T(tq), .O(dpad[i]));
        IDDR2 #(.DDR_ALIGNMENT("C0"), .INIT_Q0(1'b0), .INIT_Q1(1'b0), .SRTYPE("SYNC")) r (
            .Q0(l0[i]), .Q1(l1[i]), .C0(gd), .C1(~gd), .CE(1'b1), .D(dpad[i]), .R(1'b0), .S(1'b0));
    end endgenerate
    // logic-analyser config (USER2 sig 61): trigger mask/value, optional edge on channel lch (lpol 1 = falling); 5D [38] LA mode, [39] 200 MS/s
    reg la = 1'b0, la200 = 1'b0, ledge = 1'b0, lpol = 1'b0;
    reg [15:0] lmask = 16'h0, lval = 16'h0;
    reg [3:0] lch = 4'h0;
    reg [15:0] lx0 = 16'h0, lx1 = 16'h0, lxp = 16'h0;
    reg lev = 1'b0, lev1 = 1'b0, lev2 = 1'b0, half = 1'b0, llo = 1'b0, llo1 = 1'b0, llo2 = 1'b0, tph = 1'b0, tseen = 1'b0;
    reg [15:0] lhold = 16'h0;
    function lhit;                                     // trigger condition for sample s with previous sample p
        input [15:0] s, p;
        lhit = (((s ^ lval) & lmask) == 16'h0) && (!ledge || (lpol ? (p[lch] && !s[lch]) : (!p[lch] && s[lch])));
    endfunction

    // capture with decimation and trigger. Config (TCK domain, static while a capture runs):
    //   dec = samples skipped between stored samples (0 = 100 MS/s), pre = samples kept before the trigger,
    //   trigger on CH1 (rise sample) or CH2 (fall sample), rising/falling through lvl with hysteresis hys, ten = 0: no trigger.
    // Flow: arm -> PRE (fill pre samples) -> WAIT (circular, trigger or force allowed) -> POST (8192 - pre samples) -> done.
    // tpos = address of the trigger sample; host unrolls from tpos - pre.
    reg [12:0] ura_g = 13'h0;                          // USB-side signals used here (declared early)
    reg alive = 1'b0, ovf_st = 1'b0;
    wire ulocked;
    reg [23:0] dec = 24'h0;
    reg [12:0] pre = 13'h0;
    reg cont = 1'b0, stopt = 1'b0;                     // 5D [37]: continuous ring-buffer streaming over USB; 5A [2]: stop
    reg [2:0] ss = 3'b0;
    reg cdt = 1'b0, cst = 1'b0;                        // toggles: capture done (snapshot ready), continuous start
    reg gapf = 1'b0, wgap = 1'b0;
    reg [12:0] ra_g1 = 13'h0, ra_g2 = 13'h0;          // USB reader address (gray) synchronised into gd
    wire [12:0] ra_s = ra_g2 ^ (ra_g2 >> 1) ^ (ra_g2 >> 2) ^ (ra_g2 >> 3) ^ (ra_g2 >> 4) ^ (ra_g2 >> 5) ^ (ra_g2 >> 6)
                       ^ (ra_g2 >> 7) ^ (ra_g2 >> 8) ^ (ra_g2 >> 9) ^ (ra_g2 >> 10) ^ (ra_g2 >> 11) ^ (ra_g2 >> 12);
    wire full = (stg == 2'd3) && (wa + 13'h1 == ra_s); // ring full: drop this sample, flag the gap in the next word
    reg [12:0] wa_g = 13'h0;                           // writer address in gray for the USB side
    reg [13:0] tlo = 14'h0, thi = 14'h0, lvl = 14'h0;
    reg tsrc = 1'b0, tslope = 1'b0, ten = 1'b0, frc = 1'b0;
    reg arm = 1'b0;
    reg [2:0] as = 3'b0, fs = 3'b0;
    reg run = 1'b0, done = 1'b0, trg = 1'b0;
    reg [1:0] stg = 2'd0;                               // 0 PRE, 1 WAIT, 2 POST, 3 continuous
    reg [12:0] wa = 13'h0, tpos = 13'h0;
    reg [13:0] cnt = 14'h0;
    reg [23:0] dc = 24'h0;
    reg [31:0] wd = 32'h0, d1 = 32'h0, d2 = 32'h0, d3 = 32'h0;
    reg we = 1'b0;
    reg [12:0] wad = 13'h0;
    reg [31:0] mem [0:8191];
    reg [13:0] tx = 14'h0;
    reg tarm = 1'b0, tev = 1'b0, tpend = 1'b0, tfo = 1'b0;
    reg stb = 1'b0;                                    // registered (dc == 0): next-state computed a cycle early for timing
    // scope sampling mode (5D [41:40]): 0 decimate, 1 average (N = 2^avk samples, avk = 5D [46:42], 2..16; stored as two
    // 16-bit means with 2 fraction bits), 2 min/max (two words per interval: min, then max tagged by bit 31; needs dec >= 1)
    reg [1:0] smode = 2'd0;
    reg [4:0] avk = 5'd2;
    reg stb_d = 1'b0;
    wire mm = !la && smode == 2'd2, avg = !la && smode == 2'd1;
    wire wstb = mm ? (stb || stb_d) : stb && (!la || la200 || half);   // LA below 200 MS/s packs two samples per word
    reg [29:0] acc1 = 30'h0, acc2 = 30'h0, accf1 = 30'h0, accf2 = 30'h0;
    reg [13:0] mn1 = 14'h3fff, mn2 = 14'h3fff, mx1 = 14'h0, mx2 = 14'h0, mxl1 = 14'h0, mxl2 = 14'h0;
    wire [13:0] s1 = d3[13:0], s2 = d3[29:16];
    wire [13:0] mnf1 = s1 < mn1 ? s1 : mn1, mnf2 = s2 < mn2 ? s2 : mn2, mxf1 = s1 > mx1 ? s1 : mx1, mxf2 = s2 > mx2 ? s2 : mx2;
    reg [31:0] wdA = 32'h0;
    reg we_d = 1'b0;
    reg [12:0] wad_d = 13'h0;
    wire [4:0] ash = avk - 5'd2;
    always @(posedge gd) begin
        as <= {as[1:0], arm}; fs <= {fs[1:0], frc}; ss <= {ss[1:0], stopt}; capev <= 1'b0;
        ra_g1 <= ura_g; ra_g2 <= ra_g1; wa_g <= wa ^ (wa >> 1);
        // trigger detector at full rate
        tx <= tsrc ? qf : qr;
        lx0 <= l0; lx1 <= l1; lxp <= la200 ? lx1 : lx0;
        lev <= run && (lhit(lx0, lxp) || (la200 && lhit(lx1, lx0)));
        lev1 <= lev; lev2 <= lev1;
        llo <= run && lhit(lx0, lxp); llo1 <= llo; llo2 <= llo1;   // 200 MS/s: did the first (rising-edge) sample match?                     // LA data has two more stages than the analog path: align (measured 2 samples)
        if (!run) begin tarm <= 1'b0; tev <= 1'b0; end
        else if (!tslope) begin if (tx < tlo) tarm <= 1'b1; tev <= tarm && tx >= lvl; if (tarm && tx >= lvl) tarm <= 1'b0; end
        else begin if (tx > thi) tarm <= 1'b1; tev <= tarm && tx <= lvl; if (tarm && tx <= lvl) tarm <= 1'b0; end
        // storage
        // LA words: 200 MS/s = {falling, rising} sample of each clock; otherwise two consecutive stored samples {new, old}
        d1 <= !la ? {2'b0, qf, 2'b0, qr} : la200 ? {lx1, lx0} : {lx0, 16'h0}; d2 <= d1; d3 <= d2;   // 3-cycle trigger latency
        wd <= (la && !la200) ? {d3[31:16], lhold} : d3;   // packed LA: older sample held from the previous strobe, same delay
        if (mm) wd <= stb ? {2'b00, mnf2, 2'b00, mnf1} : {2'b10, mxl2, 2'b00, mxl1};   // min word, then max word (bit 31)
        // min/max and average accumulate every raw sample (d3, aligned with the trigger); the strobe sample closes an interval
        stb_d <= run && stb;
        if (!run || stb) begin
            mn1 <= 14'h3fff; mn2 <= 14'h3fff; mx1 <= 14'h0; mx2 <= 14'h0; acc1 <= 30'h0; acc2 <= 30'h0;
            if (stb) begin mxl1 <= mxf1; mxl2 <= mxf2; accf1 <= acc1 + s1; accf2 <= acc2 + s2; end
        end else begin
            mn1 <= mnf1; mn2 <= mnf2; mx1 <= mxf1; mx2 <= mxf2; acc1 <= acc1 + s1; acc2 <= acc2 + s2;
        end
        wdA <= {accf2 >> ash, 16'h0} | ((accf1 >> ash) & 32'hffff);   // means x4 (two fraction bits)
        we_d <= we; wad_d <= wad;
        wad <= wa; we <= run && wstb && !full; wgap <= gapf;
        if (avg ? we_d : we) mem[avg ? wad_d : wad] <= avg ? wdA : la ? wd : (mm ? {wd[31], wgap, wd[29:0]} : {1'b0, wgap, wd[29:0]});
        // bit 30: samples dropped just before this word (continuous mode); average words use all 32 bits
        if (stb && la && !la200) begin half <= ~half; lhold <= d3[31:16]; end
        if (as[2] != as[1]) begin
            run <= 1'b1; done <= 1'b0; trg <= 1'b0; wa <= 13'h0; dc <= 24'h0; stb <= 1'b1; tpend <= 1'b0; gapf <= 1'b0; half <= 1'b0; tseen <= 1'b0;
            if (cont) begin stg <= 2'd3; cst <= ~cst; end
            else if (pre == 13'h0) begin stg <= 2'd1; cnt <= 14'h0; end else begin stg <= 2'd0; cnt <= {1'b0, pre}; end
        end else if (ss[2] != ss[1]) begin
            run <= 1'b0;
        end else if (run) begin
            dc <= stb ? dec : dc - 24'h1;
            stb <= stb ? (dec == 24'h0) : (dc == 24'h1);
            if (stg == 2'd1 && !tpend) begin
                if (ten && (csrc != 3'd0 ? xev : la ? lev1 : tev)) begin tpend <= 1'b1; tfo <= 1'b0; capev <= 1'b1; if (la200) tph <= !llo1; end
                else if (fs[2] != fs[1] || !ten) begin tpend <= 1'b1; tfo <= 1'b1; end
            end
            // packed LA: the first stored sample after the trigger is the old half of the word if it arrives on a non-write strobe
            if (stb && la && !la200 && stg == 2'd1 && tpend && !tseen) begin tseen <= 1'b1; tph <= half; end
            if (wstb) begin
                if (stg != 2'd3) wa <= wa + 13'h1;
                case (stg)
                2'd0: begin cnt <= cnt - 14'h1; if (cnt == 14'h1) stg <= 2'd1; end
                2'd1: if (tpend) begin                     // this sample is the trigger sample; 8191 - pre more follow
                    tpos <= wa; trg <= !tfo; stg <= 2'd2; cnt <= 14'd8191 - {1'b0, pre};
                    if (pre == 13'h1fff) begin run <= 1'b0; done <= 1'b1; cdt <= ~cdt; end
                end
                2'd2: begin if (cnt == 14'h1) begin run <= 1'b0; done <= 1'b1; cdt <= ~cdt; end cnt <= cnt - 14'h1; end
                default: if (full) gapf <= 1'b1; else begin wa <= wa + 13'h1; gapf <= 1'b0; end   // continuous
                endcase
            end
        end
    end

    // H12 frequency: cycles per 12000 P7 cycles (1 ms)
    reg [13:0] pc = 14'h0;
    reg gate = 1'b0;
    always @(posedge g0) if (pc == 14'd11999) begin pc <= 14'h0; gate <= ~gate; end else pc <= pc + 14'h1;
    reg [2:0] gs = 3'b0;
    reg [16:0] hc = 17'h0, khz = 17'h0;
    always @(posedge gd) begin
        gs <= {gs[1:0], gate};
        if (gs[2] != gs[1]) begin khz <= hc; hc <= 17'h1; end else hc <= hc + 17'h1;
    end

    // USER2 control/status
    reg [55:0] sr2 = 56'h0;
    reg [5:1] acfg = 5'b0;
    reg [12:0] alast = 13'h0;
    reg csel = 1'b0;                                   // sig 62: next USER2 capture returns {A6, DIO pins}
    reg esel = 1'b0;                                   // sig 69: next USER2 capture returns {A7, busy, address, IC37 word}
    reg [7:0] mwa = 8'h0; reg mwt = 1'b0;            // sig 69 [7:0]: IC37 word address; every sig 69 update starts one READ
    wire mwbusy, mwckw; wire [15:0] mwd;
    wire locked;
    always @(posedge tck) begin
        if (sel2 && capture) sr2 <= esel ? {8'hA7, 23'b0, mwbusy, mwa, mwd} : csel ? {8'hA6, 32'h0, dpad} : {8'hA5, 2'b0, ovf_st, alive, ulocked, locked, ld, done, run, stg, tpos, 7'b0, khz};
        else if (sel2 && shift) sr2 <= {tdi, sr2[55:1]};
        if (sel2 && update && sr2[55:48] == 8'h5A && sr2[0]) arm <= ~arm;
        if (sel2 && update && sr2[55:48] == 8'h5A && sr2[1]) frc <= ~frc;
        if (sel2 && update && sr2[55:48] == 8'h5D) begin dec <= sr2[23:0]; pre <= sr2[36:24]; cont <= sr2[37]; la <= sr2[38]; la200 <= sr2[39];
            smode <= sr2[41:40]; avk <= sr2[46:42]; end
        if (sel2 && update && sr2[55:48] == 8'h60) begin dvo <= sr2[15:0]; dvoe <= sr2[31:16]; end
        if (sel2 && update && sr2[55:48] == 8'h61) begin lmask <= sr2[15:0]; lval <= sr2[31:16]; lch <= sr2[35:32]; ledge <= sr2[36]; lpol <= sr2[37]; end
        if (sel2 && update && sr2[55:48] == 8'h63) begin pg_en <= sr2[0]; pg_sq <= sr2[1]; end
        if (sel2 && update && sr2[55:48] == 8'h64) begin pgrun <= sr2[0]; pgload <= sr2[1]; pgonce <= sr2[2]; pglast <= sr2[26:16]; end
        if (sel2 && update && sr2[55:48] == 8'h65) pgdiv <= sr2[23:0];
        if (sel2 && update && sr2[55:48] == 8'h66) usr <= sr2[1:0];
        if (sel2 && update && sr2[55:48] == 8'h68) begin ftw_t <= sr2[31:0]; dds_t <= sr2[32]; ftog <= ~ftog; end
        if (sel2 && update && sr2[55:48] == 8'h67) begin
            csrc <= sr2[2:0]; cpol <= sr2[3]; asrc <= sr2[6:4]; psrc <= sr2[10:8]; t1o <= sr2[14:12]; t2o <= sr2[18:16];
        end
        if (sel2 && update) csel <= (sr2[55:48] == 8'h62);
        if (sel2 && update) esel <= (sr2[55:48] == 8'h69);
        if (sel2 && update && sr2[55:48] == 8'h69) begin mwa <= sr2[7:0]; mwt <= ~mwt; end
        if (sel2 && update && sr2[55:48] == 8'h5A && sr2[2]) stopt <= ~stopt;
        if (sel2 && update && sr2[55:48] == 8'h5E) begin
            lvl <= sr2[13:0]; tlo <= sr2[13:0] - sr2[27:14]; thi <= sr2[13:0] + sr2[27:14];
            tsrc <= sr2[28]; tslope <= sr2[29]; ten <= sr2[30];
        end
        if (sel2 && update && sr2[55:48] == 8'h5B) begin acfg <= sr2[5:1]; alast <= sr2[28:16]; end
        if (sel2 && update && sr2[55:48] == 8'h5C) gsw <= sr2[3:0];
    end
    assign tdo2 = sr2[0];

    // USER3 pin port
    // D8 H11 J11 K13 released, as WaveForms leaves them idle; A11 M4 low; DIO0 released; /CS_AWG high, SCLK_AWG low,
    // SDIO_AWG released, SET_FS_AWG1/2 low
    reg [31:0] outv = 32'h0815FF79, oe = 32'hDB17C00F;   // P3 P5 (bits 7 8) released: driving them breaks USB reads
    wire [31:0] pin_in;
    reg [63:0] sr3 = 64'h0;
    always @(posedge tck) begin
        if (sel3 && capture) sr3 <= {oe, pin_in};
        else if (sel3 && shift) sr3 <= {tdi, sr3[63:1]};
        if (sel3 && update) begin outv <= sr3[31:0]; oe <= sr3[63:32]; end
    end
    assign tdo3 = sr3[0];
    // bits 4 5 6 9 10 12 (N8 N10 N11 L8 M8 N7) now belong to the USB FIFO: kept as internal-only bits so cap.c numbering holds
    generate for (i = 0; i < 32; i = i + 1) begin : io
        if (i == 4 || i == 5 || i == 6 || i == 9 || i == 10 || i == 12 || i == 26) begin : v
            assign pin_in[i] = outv[i];
        end else begin : p
            IOBUF b (.IO(pp[i - (i > 4) - (i > 5) - (i > 6) - (i > 9) - (i > 10) - (i > 12) - (i > 26)]),
                .I(i == 7 && mwbusy ? mwckw : outv[i]), .T(i == 7 && mwbusy ? 1'b0 : ~oe[i]), .O(pin_in[i]));   // bit 7 = P3 = IC37 CLK while a READ runs
        end
    end endgenerate


    // ---- IC37 calibration EEPROM (93LC66B, x16, Microwire), READ only: g0 (12 MHz) domain, one step = 8 cycles (667 ns) ----
    // steps 0-1 CS low then high; 2-34 command start 1, opcode 10, A7..A0, three steps per bit (CLK low, high, low);
    // 35 DI/DO released; 36-69 CLK high (even, sampled at its end) / low (odd): the first sample is D15 (the dummy 0
    // comes on the last address clock); 70 CS low. Words are stored low byte first by WaveForms.
    reg [2:0] mwts = 3'b0, mwc = 3'b0; reg [6:0] mws = 7'h0; reg [1:0] mwk = 2'b0; reg [10:0] mwcmd = 11'h0;
    reg mwb = 1'b0, mwcsr = 1'b0, mwck = 1'b0, mwdo = 1'b0, mwoe = 1'b0; reg [15:0] mwdr = 16'h0;
    wire mwin;
    assign mwbusy = mwb; assign mwckw = mwck; assign mwd = mwdr; assign mw_cs = mwcsr;
    IOBUF bmw (.IO(mw_dio), .I(mwdo), .T(~mwoe), .O(mwin));
    always @(posedge g0) begin
        mwts <= {mwts[1:0], mwt};
        if (!mwb) begin
            mwcsr <= 1'b0; mwck <= 1'b0; mwoe <= 1'b0;
            if (mwts[2] != mwts[1]) begin mwb <= 1'b1; mws <= 7'h0; mwc <= 3'h0; mwk <= 2'h0; mwcmd <= {3'b110, mwa}; end
        end else begin
            mwc <= mwc + 3'h1;
            mwcsr <= (mws >= 7'd1 && mws <= 7'd69);
            mwoe <= (mws <= 7'd34); mwdo <= (mws >= 7'd2 && mws <= 7'd34) && mwcmd[10];
            mwck <= (mws >= 7'd2 && mws <= 7'd34) ? (mwk == 2'd1) : (mws >= 7'd36 && mws <= 7'd69) ? ~mws[0] : 1'b0;
            if (mwc == 3'h7) begin
                mws <= mws + 7'h1;
                if (mws >= 7'd2 && mws <= 7'd34) begin if (mwk == 2'd2) begin mwk <= 2'd0; mwcmd <= {mwcmd[9:0], 1'b0}; end else mwk <= mwk + 2'd1; end
                if (mws >= 7'd36 && mws <= 7'd66 && !mws[0]) mwdr <= {mwdr[14:0], mwin};
                if (mws == 7'd70) mwb <= 1'b0;
            end
        end
    end

    // USER4 BRAM readout
    reg [31:0] sr4 = 32'h0;
    reg [4:0] bc = 5'h0;
    reg [31:0] li = 32'h0;
    reg [12:0] lad = 13'h1fff;
    reg [27:0] amem [0:8191];
    always @(posedge tck) begin
        if (sel4 && capture) begin sr4 <= {8'hA5, trg, tph, 9'b0, tpos}; bc <= 5'h0; lad <= 13'h1fff; end
        else if (sel4 && shift) begin
            bc <= bc + 5'h1;
            li <= {tdi, li[31:1]};
            if (bc == 5'h1f) begin
                sr4 <= 32'h0;
                if (acfg[1]) begin amem[lad] <= {li[30:17], li[14:1]}; lad <= lad + 13'h1; end   // word {tdi, li[31:1]}: B [29:16], A [13:0]
                if (pgload) begin pmem[lad[10:0]] <= li[16:1]; if (!acfg[1]) lad <= lad + 13'h1; end   // pattern: low 16 bits
            end
            else sr4 <= {tdi, sr4[31:1]};
        end
    end
    assign tdo4 = sr4[0];


    // ---- USB: FT232H 245 synchronous FIFO (DPTI port 1), scope memory read side ----
    // Data out: 30-bit words {flags[1:0], fall[13:0], rise[13:0]} as five 6-bit symbols, low symbol first; a symbol rides
    // on D1 (bit 0) and D3..D7 (bits 1..5). D0 is the FPGA's JTAG TCK line: held low for the whole session. D2 (TDO) unused.
    // Flow control: each byte the host sends grants 512 symbols. Snapshot: after every finished capture the reader restarts
    // at tpos - pre for 8192 words (time order). Continuous: reader follows the ring writer; flag bit 30 marks dropped samples.
    wire c60b, uc0, uclk;
    IBUFG ic60 (.I(clk60), .O(c60b));
    reg udcm_rst = 1'b1;
    DCM_SP #(.CLKIN_PERIOD(16.667), .CLK_FEEDBACK("1X"), .DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"))
        udcm (.CLKIN(c60b), .CLKFB(uclk), .RST(udcm_rst), .CLK0(uc0), .LOCKED(ulocked),
              .CLK90(), .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(), .CLKDV(), .CLKFX(), .CLKFX180(), .STATUS(),
              .DSSEN(1'b0), .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE());
    BUFG bu (.I(uc0), .O(uclk));
    reg [5:0] tgl = 6'h0;
    always @(posedge c60b) tgl <= tgl + 6'h1;
    reg [2:0] uts = 3'b0;
    reg [7:0] uidle = 8'hff;
    reg [15:0] uwd = 16'h0;
    reg [1:0] ulk = 2'b0;
    always @(posedge g0) begin                         // CLKOUT watchdog: DCM reset while the clock is absent; bus release
        uts <= {uts[1:0], tgl[5]}; ulk <= {ulk[0], ulocked};
        if (uts[2] != uts[1]) uidle <= 8'h0; else if (uidle != 8'hff) uidle <= uidle + 8'h1;
        alive <= (uidle <= 8'd12);
        if (uidle > 8'd24) begin udcm_rst <= 1'b1; uwd <= 16'h0; end
        else if (udcm_rst) begin uwd <= uwd + 16'h1; if (uwd == 16'd120) udcm_rst <= 1'b0; end
        else if (!ulk[1]) begin uwd <= uwd + 16'h1; if (uwd == 16'd24000) begin udcm_rst <= 1'b1; uwd <= 16'h0; end end
        else uwd <= 16'd120;
    end

    (* IOB = "TRUE" *) reg rxf_q = 1'b1, txe_q = 1'b1;
    (* IOB = "TRUE" *) reg [5:0] udout = 6'h0;
    (* IOB = "TRUE" *) reg rd_p = 1'b1, wr_p = 1'b1, oe_p = 1'b1;
    reg rd_i = 1'b1, wr_i = 1'b1, uden = 1'b0;
    assign ud[0] = alive ? 1'b0 : 1'bz;
    assign ud[6:1] = (uden && alive) ? udout : 6'bz;
    assign rd_n = rd_p; assign wr_n = wr_p; assign oe_n = oe_p;
    assign siwu = 1'b1;

    // reader
    reg [12:0] ura = 13'h0;
    reg [13:0] urem = 14'h0;
    reg ucont = 1'b0;
    reg [35:0] wb = 36'h0;
    reg [2:0] si = 3'd5;                               // last symbol of wb sent (= nlast: word used up)
    reg ula = 1'b0;
    reg uavg = 1'b0;
    wire [2:0] nlast = (ula || uavg) ? 3'd5 : 3'd4;   // LA and average words are 32 bits = 6 symbols, scope words 30 bits = 5
    reg [31:0] mq = 32'h0;
    always @(posedge uclk) mq <= mem[ura];
    reg [12:0] wg1 = 13'h0, wg2 = 13'h0;
    wire [12:0] wa_u = wg2 ^ (wg2 >> 1) ^ (wg2 >> 2) ^ (wg2 >> 3) ^ (wg2 >> 4) ^ (wg2 >> 5) ^ (wg2 >> 6)
                       ^ (wg2 >> 7) ^ (wg2 >> 8) ^ (wg2 >> 9) ^ (wg2 >> 10) ^ (wg2 >> 11) ^ (wg2 >> 12);
    reg [2:0] cds = 3'b0, css = 3'b0;
    reg [1:0] ulks = 2'b0;
    reg rd_prev = 1'b1, wr_prev = 1'b1;
    wire acc = !wr_prev && !txe_q;                     // symbol presented two edges ago was taken
    wire got = !rd_prev && !rxf_q;                     // request byte taken at the last edge
    reg [23:0] quota = 24'h0;
    wire [35:0] mqp = (ula || uavg) ? {4'h0, mq} : {6'h0, mq[31:30], mq[29:16], mq[13:0]};
    wire take = acc && si == nlast;
    wire [2:0] si_n = acc ? (si == nlast ? 3'd0 : si + 3'd1) : si;
    wire [35:0] wb_n = take ? mqp : wb;
    wire [12:0] ura_n = take ? ura + 13'h1 : ura;
    wire [13:0] urem_n = take ? urem - 14'h1 : urem;
    wire [23:0] quota_n = quota + (got ? 24'd512 : 24'd0) - (acc ? 24'd1 : 24'd0);
    wire wordok_n = ucont ? (wa_u != ura_n) : (urem_n != 14'h0);
    wire symok_n = (si_n != nlast) || wordok_n;
    reg [5:0] nsym;
    always @* case (si_n)
        3'd0: nsym = wb_n[11:6]; 3'd1: nsym = wb_n[17:12]; 3'd2: nsym = wb_n[23:18]; 3'd3: nsym = (ula || si_n != nlast) ? wb_n[29:24] : mqp[5:0];
        3'd4: nsym = (si_n != nlast) ? wb_n[35:30] : mqp[5:0];
        default: nsym = mqp[5:0];
    endcase
    reg [1:0] us = 2'd0;
    reg ph = 1'b0, ovf_u = 1'b0;
    always @(posedge uclk) begin
        rxf_q <= rxf_n; txe_q <= txe_n;
        rd_prev <= rd_i; wr_prev <= wr_i;
        wg1 <= wa_g; wg2 <= wg1; ura_g <= ura_n ^ (ura_n >> 1);
        cds <= {cds[1:0], cdt}; css <= {css[1:0], cst}; ulks <= {ulks[0], ulocked};
        si <= si_n; wb <= wb_n; ura <= ura_n; urem <= urem_n; quota <= quota_n;
        if (take && mq[30] && !ula && !uavg) ovf_u <= 1'b1;
        ula <= la; uavg <= avg;
        if (cds[2] != cds[1]) begin ura <= tpos - pre; urem <= 14'h2000; ucont <= 1'b0; si <= nlast; quota <= 24'h0; end
        if (css[2] != css[1]) begin ura <= 13'h0; urem <= 14'h0; ucont <= 1'b1; si <= nlast; quota <= 24'h0; ovf_u <= 1'b0; end
        if (!ulks[1]) begin
            us <= 2'd0; begin rd_i <= 1'b1; rd_p <= 1'b1; end begin wr_i <= 1'b1; wr_p <= 1'b1; end oe_p <= 1'b1; uden <= 1'b0; ph <= 1'b0;
        end else case (us)
        2'd0: begin
            begin rd_i <= 1'b1; rd_p <= 1'b1; end begin wr_i <= 1'b1; wr_p <= 1'b1; end uden <= 1'b0; ph <= 1'b0;
            if (!rxf_q) begin oe_p <= 1'b0; us <= 2'd1; end
            else if (!txe_q && symok_n && quota_n != 24'h0 && wr_prev) begin oe_p <= 1'b1; us <= 2'd3; uden <= 1'b1; end
        end
        2'd1: begin                                    // OE# low, then RD# low while request bytes remain
            if (rxf_q) begin begin rd_i <= 1'b1; rd_p <= 1'b1; end oe_p <= 1'b1; us <= 2'd2; end
            else begin rd_i <= 1'b0; rd_p <= 1'b0; end
        end
        2'd2: us <= 2'd0;
        2'd3: begin                                    // two clocks per symbol: present, then wait for TXE# at the sample edge
            if (ph) begin begin wr_i <= 1'b1; wr_p <= 1'b1; end ph <= 1'b0; end
            else if (txe_q || !symok_n || quota_n == 24'h0) begin begin wr_i <= 1'b1; wr_p <= 1'b1; end us <= 2'd0; end
            else begin begin wr_i <= 1'b0; wr_p <= 1'b0; end ph <= 1'b1; udout <= nsym; end
        end
        endcase
    end
    always @(posedge tck) ovf_st <= ovf_u;

    // AWG playback (DCM copy of H12; CLK0 for data, CLK90 for DCLKIO)
    wire c0u, c90u, ga0, ga90;
    reg [2:0] drs = 3'b0;
    always @(posedge g0) drs <= {drs[1:0], acfg[5]};
    DCM_SP #(.CLKIN_PERIOD(10.0), .CLK_FEEDBACK("1X"), .CLKOUT_PHASE_SHIFT("NONE"), .DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"))
        dcm (.CLKIN(h12b), .CLKFB(ga0), .RST(drs[2]), .CLK0(c0u), .CLK90(c90u), .LOCKED(locked),
             .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(), .CLKDV(), .CLKFX(), .CLKFX180(), .STATUS(),
             .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(), .DSSEN(1'b0));
    BUFG ba0 (.I(c0u), .O(ga0));
    BUFG ba90 (.I(c90u), .O(ga90));
    reg [2:0] ps = 3'b0;
    reg [12:0] pa = 13'h0;
    reg [27:0] aq = 28'h0;
    reg [13:0] h0 = 14'h0, h1 = 14'h0;
    // DDS (USER2 sig 68: [31:0] frequency tuning word, [32] DDS on): f = ftw * 100 MHz / 2^32; the 8192-word AWG memory is
    // the waveform table (address = phase[31:19]); both channels share the phase, each plays its own half of the table
    reg [31:0] ftw_t = 32'h0;
    reg dds_t = 1'b0, ftog = 1'b0;
    reg [2:0] fts = 3'b0;
    reg [31:0] ftw = 32'h0, dph = 32'h0;
    reg dds = 1'b0;
    wire [32:0] phs = {1'b0, dph} + {1'b0, ftw};
    reg ago = 1'b0, ago_d = 1'b0;
    reg [2:0] ats = 3'b0;
    reg [2:0] asrc_a = 3'd0;
    always @(posedge ga0) begin
        ps <= {ps[1:0], acfg[2]}; ats <= {ats[1:0], atog}; asrc_a <= asrc; ago_d <= ago;
        if (!ps[2]) ago <= 1'b0; else if (asrc_a == 3'd0 || ats[2] != ats[1]) ago <= 1'b1;
        fts <= {fts[1:0], ftog}; if (fts[2] != fts[1]) begin ftw <= ftw_t; dds <= dds_t; end
        if (!ago) dph <= 32'h0; else dph <= phs[31:0];
        if (ago && (!ago_d || (dds ? phs[32] : pa == alast))) awt <= ~awt;   // start / loop (DDS: phase wrap) event to gd
        aq <= amem[dds ? dph[31:19] : pa];
        if (!ago) pa <= 13'h0; else pa <= (pa == alast) ? 13'h0 : pa + 13'h1;
        h0 <= !ago ? 14'h0 : acfg[4] ? aq[27:14] : aq[13:0];
        h1 <= !ago ? 14'h0 : acfg[4] ? aq[13:0] : aq[27:14];
    end
    generate for (i = 0; i < 14; i = i + 1) begin : od
        ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) o (.Q(da[i]), .C0(ga0), .C1(~ga0), .CE(1'b1),
            .D0(h0[i]), .D1(h1[i]), .R(1'b0), .S(1'b0));
    end endgenerate
    ODDR2 #(.DDR_ALIGNMENT("C0"), .SRTYPE("ASYNC")) oc (.Q(dclk), .C0(ga90), .C1(~ga90), .CE(1'b1),
        .D0(~acfg[3]), .D1(acfg[3]), .R(1'b0), .S(1'b0));

    // ADF4360 writer (as pllclk)
    reg busy = 1'b0, req = 1'b0;
    reg [39:0] sr1 = 40'h0;
    reg [23:0] cmd = 24'h0;
    always @(posedge tck) begin
        if (sel1 && capture) sr1 <= {8'hA5, 15'h0, busy, 15'h0, ld};
        else if (sel1 && shift) sr1 <= {tdi, sr1[39:1]};
        if (sel1 && update && sr1[36]) begin cmd <= sr1[23:0]; req <= ~req; end
    end
    assign tdo1 = sr1[0];
    reg [2:0] rqs = 3'b0, div = 3'b0;
    reg [23:0] w = 24'h0;
    reg [5:0] step = 6'h0;
    reg le_r = 1'b1, ck_r = 1'b0, d_r = 1'b0;
    always @(posedge g0) begin
        rqs <= {rqs[1:0], req};
        div <= div + 3'b1;
        if (rqs[2] != rqs[1]) begin w <= cmd; busy <= 1'b1; step <= 6'h1; end
        else if (busy && div == 3'b0) begin
            if (step == 6'h1) begin le_r <= 1'b0; ck_r <= 1'b0; step <= 6'h2; end
            else if (step < 6'd50) begin
                if (!step[0]) begin ck_r <= 1'b0; d_r <= w[23 - (step[5:1] - 5'd1)]; end
                else ck_r <= 1'b1;
                step <= step + 6'h1;
            end else begin ck_r <= 1'b0; d_r <= 1'b0; le_r <= 1'b1; busy <= 1'b0; step <= 6'h0; end
        end
    end
    assign le = le_r; assign sck = ck_r; assign sdo = d_r;
endmodule
