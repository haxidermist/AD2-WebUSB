// AD2 WebUSB: FPGA design for the Digilent Analog Discovery 2 (Spartan-6 XC6SLX16, ISE 14.7).
//
// The host (the browser app) controls everything through the FPGA's JTAG port (the FT232H in MPSSE mode) and moves
// data through the FT232H's synchronous FIFO.
//
// JTAG user registers (BSCAN_SPARTAN6)
//   USER1  ADF4360 clock synthesiser writer (adf4360_spi.v)
//   USER2  56-bit command / status register. Update executes a command (codes in ad2_defs.vh); capture reads
//          {SIG_STATUS, 2'b11, overflow, fifo_alive, fifo_locked, awg_locked, pll_lock, done, run, stage[1:0],
//           tpos[12:0], 7'b0, khz[16:0]}; bit 47 announces the 8-bit FIFO, bit 46 FIFO command packets, khz = ADC
//          clock cycles per ms. After CMD_PINS / CMD_EEPROM the next capture returns {SIG_PINS, 32'b0, DIO pins} /
//          {SIG_EEPROM, 23'b0, busy, address, word} instead, and after CMD_FREQ_READ a frequency-counter result word
//          {SIG_FREQ, measurement number, word[39:0]}.
//   USER3  64-bit control port {oe[31:0], out[31:0]} for slow bit-banged I/O; capture returns {oe, pin levels}.
//          Bit assignment in ad2_top.ucf; the reset values are WaveForms' idle levels.
//   USER4  memory port: capture loads the 32-bit header {SIG_STATUS, triggered, half, 9'b0, tpos}; then every 32 bits
//          shifted in are written to the AWG memory (CMD_AWG bit 1) and/or the pattern memory (CMD_PG bit 1) at
//          addresses 8191 (a dummy first word), 0, 1, ...
//
// Commands are decoded in the always-running 12 MHz domain, from JTAG or from FIFO command packets (usb_fifo.v). A JTAG
// write therefore takes effect about 0.5 us after Update-DR; the app clocks 16 idle TCKs after each USER2 write.
// CMD_PINS, CMD_EEPROM and CMD_FREQ_READ are decoded in the JTAG domain, because their result must be ready for the very next scan.
//
// Clock domains: tck (JTAG, only while scanning), clk12 (P7, 12 MHz, always running), clk100 (ADC clock from the
// ADF4360 via H12), the AWG DCM copy of clk100, and the FIFO clock (60 MHz, only during FIFO sessions). Values cross
// between domains as quasi-static registers plus toggle signals with two- or three-stage synchronisers.
`default_nettype none
module ad2_top (
    input  wire        clk12_pin,                     // P7: 12 MHz oscillator
    // scope front end and ADC
    output wire        en_hg_sc1, output wire en_lg_sc1, output wire en_hg_sc2, output wire en_lg_sc2,   // ADG612 gain switches
    input  wire        adc_clk,                       // H12: AD9648 CLKOUT (100 MHz)
    input  wire [13:0] adc_d,                         // AD9648 interleaved CMOS data, Gray coding off in this design
    // ADF4360 clock synthesiser
    output wire        clkd_le, output wire clkd_sclk, output wire clkd_sdio, input wire clkd_ld,
    // AWG DAC (AD9717)
    output wire [13:0] awg_d, output wire awg_clkio,
    // supplies and board control
    output wire        en_dvcc1v8, output wire en_avcc, output wire adg621_in,
    output wire        pwrgd_usr,                     // N5: driven together with EN_PWR_USR, as WaveForms does (see the README)
    output wire        en_pwr_usr,
    inout  wire [24:0] port_pad,                      // control-port pads (USER3 bits other than 4 5 6 9 10 12 26)
    // calibration EEPROM (CLK is control-port bit 7, P3)
    output wire        ee_cs, inout wire ee_dio,
    // digital I/O and triggers
    inout  wire [15:0] dio, inout wire [1:0] trig,
    // FT232H synchronous FIFO
    input  wire        ft_clk, input wire ft_rxf_n, input wire ft_txe_n,
    output wire        ft_rd_n, output wire ft_wr_n, output wire ft_oe_n, output wire ft_siwu_n,
    inout  wire [7:0]  ft_d
);
    `include "ad2_defs.vh"
    genvar i;

    // ---------------------------------------------------------------------------------------------------------------
    // Clocks and JTAG
    // ---------------------------------------------------------------------------------------------------------------
    wire clk12, adc_clk_b, clk100;
    BUFG    b_clk12 (.I(clk12_pin), .O(clk12));
    IBUFG   b_adc_clk (.I(adc_clk), .O(adc_clk_b));
    BUFG    b_clk100 (.I(adc_clk_b), .O(clk100));

    wire tck_raw, tck, tdi, capture, shift, update, sel1, sel2, sel3, sel4, tdo1, tdo2, tdo3, tdo4;
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(1)) bs1 (.CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel1),
        .SHIFT(shift), .TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo1));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(2)) bs2 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel2),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo2));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(3)) bs3 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel3),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo3));
    BSCAN_SPARTAN6 #(.JTAG_CHAIN(4)) bs4 (.CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel4),
        .SHIFT(), .TCK(), .TDI(), .TMS(), .UPDATE(), .TDO(tdo4));
    BUFG b_tck (.I(tck_raw), .O(tck));                 // global TCK: local routing broke the longer chains

    // ADC bus: IDDR2 on both edges of the ADC clock; rise = CH1, fall = CH2, both aligned to the rising edge
    wire [13:0] adc_rise, adc_fall;
    generate for (i = 0; i < 14; i = i + 1) begin : g_adc
        IDDR2 #(.DDR_ALIGNMENT("C0"), .INIT_Q0(1'b0), .INIT_Q1(1'b0), .SRTYPE("SYNC")) r (
            .Q0(adc_rise[i]), .Q1(adc_fall[i]), .C0(clk100), .C1(~clk100), .CE(1'b1), .D(adc_d[i]), .R(1'b0), .S(1'b0));
    end endgenerate

    // ADC clock monitor: clk100 cycles per 12000 clk12 cycles (1 ms) = frequency in kHz
    reg  [13:0] mc = 14'h0;
    reg         gate = 1'b0;
    always @(posedge clk12) if (mc == 14'd11999) begin mc <= 14'h0; gate <= ~gate; end else mc <= mc + 14'h1;
    reg  [2:0]  gate_s = 3'b0;
    reg  [16:0] hc = 17'h0, khz = 17'h0;
    always @(posedge clk100) begin
        gate_s <= {gate_s[1:0], gate};
        if (gate_s[2] != gate_s[1]) begin khz <= hc; hc <= 17'h1; end else hc <= hc + 17'h1;
    end

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration registers (written by the command decoder)
    // ---------------------------------------------------------------------------------------------------------------
    reg  [3:0]  gsw = 4'b0101;                         // {EN_HG_SC1, EN_LG_SC1, EN_HG_SC2, EN_LG_SC2}
    reg  [1:0]  usr = 2'b00;                           // user supplies {EN_PWR_USR, N5}
    reg         arm_t = 1'b0, force_t = 1'b0, stop_t = 1'b0;   // capture control toggles
    reg  [23:0] dec = 24'h0;
    reg  [12:0] pre = 13'h0;
    reg         cont = 1'b0, la = 1'b0, la200 = 1'b0;
    reg  [1:0]  smode = 2'd0;
    reg  [4:0]  avk = 5'd2;
    reg  [13:0] lvl = 14'h0, tlo = 14'h0, thi = 14'h0;
    reg         tsrc = 1'b0, tslope = 1'b0, ten = 1'b0;
    reg  [15:0] lmask = 16'h0, lval = 16'h0;
    reg  [3:0]  lch = 4'h0;
    reg         ledge = 1'b0, lpol = 1'b0;
    reg  [15:0] dio_out = 16'h0, dio_oe = 16'h0;
    reg         tp_count = 1'b0, tp_square = 1'b0;
    reg         pg_run = 1'b0, pg_load = 1'b0, pg_once = 1'b0;
    reg  [10:0] pg_last = 11'h0;
    reg  [23:0] pg_div = 24'h0;
    reg  [2:0]  csrc = 3'd0, asrc = 3'd0, psrc = 3'd0, t1o = 3'd0, t2o = 3'd0;
    reg         cpol = 1'b0;
    reg  [5:1]  acfg = 5'b0;                           // AWG config, see CMD_AWG
    reg  [12:0] alast = 13'h0;
    reg  [31:0] ftw_t = 32'h0;
    reg         dds_t = 1'b0, ftw_tog = 1'b0;
    reg         fc_run = 1'b0;                         // frequency counter (CMD_FREQ, CMD_FREQ_GATE)
    reg  [4:0]  fc_src = 5'd0;
    reg  [13:0] fc_level = 14'h0, fc_low = 14'h0;
    reg  [31:0] fc_gate = 32'd100000000;

    // status from the modules
    wire        run, done, trg, tph, capev, done_t, cont_t, avg, xev, awg_start_t, awg_ev_t;
    wire [1:0]  stg;
    wire [12:0] tpos;
    wire        fifo_alive, fifo_locked, awg_locked, fifo_overflow;
    wire [15:0] dio_pins;
    wire        ee_busy, ee_clk;
    wire [15:0] ee_word;
    reg         overflow_t = 1'b0;                     // fifo_overflow in the JTAG domain
    always @(posedge tck) overflow_t <= fifo_overflow;

    // ---------------------------------------------------------------------------------------------------------------
    // USER2: command / status register and command decoder
    // ---------------------------------------------------------------------------------------------------------------
    reg  [55:0] sr2 = 56'h0;
    reg         sel_pins = 1'b0, sel_ee = 1'b0;        // the next capture returns the DIO pins / the EEPROM word
    reg         sel_fc = 1'b0;                         // ... / a frequency-counter result word
    reg  [1:0]  fc_word = 2'd0;
    wire [7:0]  fc_seq;
    wire [31:0] fc_periods;
    wire [39:0] fc_cycles;
    wire [27:0] fc_first, fc_last;
    // reading word 0 takes a snapshot of the whole result, so words 1-3 come from the same measurement even when
    // a new one completes during the read (the result registers change only once per measurement)
    reg  [7:0]  fs_seq = 8'h0;
    reg  [31:0] fs_periods = 32'h0;
    reg  [39:0] fs_cycles = 40'h0;
    reg  [27:0] fs_first = 28'h0, fs_last = 28'h0;
    wire [39:0] fc_data = fc_word == 2'd0 ? {8'h0, fs_periods} : fc_word == 2'd1 ? fs_cycles
                        : fc_word == 2'd2 ? {12'h0, fs_first} : {12'h0, fs_last};
    reg  [7:0]  ee_addr = 8'h0;
    reg         ee_start = 1'b0;                       // toggles: read one EEPROM word
    reg  [55:0] jword = 56'h0;                         // last word written over JTAG
    reg         jword_t = 1'b0;                        // toggles with each JTAG write
    wire [55:0] fword;                                 // last FIFO command packet
    wire        fword_t;                               // toggles with each FIFO command packet
    reg         fword_ack = 1'b0;                      // copies fword_t once the decoder has executed it
    wire [55:0] status = {SIG_STATUS, 2'b11, overflow_t, fifo_alive, fifo_locked, awg_locked, clkd_ld, done, run, stg,
                          tpos, 7'b0, khz};
    always @(posedge tck) begin
        if (sel2 && capture) sr2 <= sel_ee ? {SIG_EEPROM, 23'b0, ee_busy, ee_addr, ee_word}
                                  : sel_pins ? {SIG_PINS, 32'h0, dio_pins} : sel_fc ? {SIG_FREQ, fs_seq, fc_data} : status;
        else if (sel2 && shift) sr2 <= {tdi, sr2[55:1]};
        if (sel2 && update) begin
            sel_pins <= (sr2[55:48] == CMD_PINS);
            sel_ee <= (sr2[55:48] == CMD_EEPROM);
            sel_fc <= (sr2[55:48] == CMD_FREQ_READ);
            if (sr2[55:48] == CMD_FREQ_READ) begin
                fc_word <= sr2[1:0];
                if (sr2[1:0] == 2'd0) begin fs_seq <= fc_seq; fs_periods <= fc_periods; fs_cycles <= fc_cycles; fs_first <= fc_first; fs_last <= fc_last; end
            end
            if (sr2[55:48] == CMD_EEPROM) begin ee_addr <= sr2[7:0]; ee_start <= ~ee_start; end
            jword <= sr2; jword_t <= ~jword_t;
        end
    end
    assign tdo2 = sr2[0];

    // decoder (12 MHz): a JTAG word (edge of jword_t) or a pending FIFO packet (fword_t != fword_ack), JTAG first
    reg  [2:0]  jword_s = 3'b0, fword_s = 3'b0;
    wire        jev = jword_s[2] != jword_s[1];
    wire        fev = !jev && fword_s[2] != fword_ack;
    wire        cev = jev || fev;
    wire [55:0] cw = jev ? jword : fword;
    wire [7:0]  op = cw[55:48];
    always @(posedge clk12) begin
        jword_s <= {jword_s[1:0], jword_t}; fword_s <= {fword_s[1:0], fword_t};
        if (fev) fword_ack <= fword_s[2];
        if (cev) case (op)
            CMD_ARM: begin
                if (cw[0]) arm_t <= ~arm_t;
                if (cw[1]) force_t <= ~force_t;
                if (cw[2]) stop_t <= ~stop_t;
            end
            CMD_AWG:      begin acfg <= cw[5:1]; alast <= cw[28:16]; end
            CMD_GAIN:     gsw <= cw[3:0];
            CMD_CAPTURE:  begin dec <= cw[23:0]; pre <= cw[36:24]; cont <= cw[37]; la <= cw[38]; la200 <= cw[39];
                                smode <= cw[41:40]; avk <= cw[46:42]; end
            CMD_TRIGGER:  begin lvl <= cw[13:0]; tlo <= cw[13:0] - cw[27:14]; thi <= cw[13:0] + cw[27:14];
                                tsrc <= cw[28]; tslope <= cw[29]; ten <= cw[30]; end
            CMD_DIO:      begin dio_out <= cw[15:0]; dio_oe <= cw[31:16]; end
            CMD_LA_TRIG:  begin lmask <= cw[15:0]; lval <= cw[31:16]; lch <= cw[35:32]; ledge <= cw[36]; lpol <= cw[37]; end
            CMD_TESTPAT:  begin tp_count <= cw[0]; tp_square <= cw[1]; end
            CMD_PG:       begin pg_run <= cw[0]; pg_load <= cw[1]; pg_once <= cw[2]; pg_last <= cw[26:16]; end
            CMD_PG_RATE:  pg_div <= cw[23:0];
            CMD_SUPPLIES: usr <= cw[1:0];
            CMD_XTRIG:    begin csrc <= cw[2:0]; cpol <= cw[3]; asrc <= cw[6:4]; psrc <= cw[10:8];
                                t1o <= cw[14:12]; t2o <= cw[18:16]; end
            CMD_DDS:      begin ftw_t <= cw[31:0]; dds_t <= cw[32]; ftw_tog <= ~ftw_tog; end
            CMD_FREQ:     begin fc_level <= cw[13:0]; fc_low <= cw[13:0] - cw[27:14]; fc_src <= cw[32:28]; fc_run <= cw[33]; end
            CMD_FREQ_GATE: fc_gate <= cw[31:0];
            default: ;
        endcase
    end

    // static board outputs
    assign {en_hg_sc1, en_lg_sc1, en_hg_sc2, en_lg_sc2} = gsw;
    assign {en_pwr_usr, pwrgd_usr} = usr;
    assign en_dvcc1v8 = 1'b1; assign en_avcc = 1'b1; assign adg621_in = 1'b1;

    // ---------------------------------------------------------------------------------------------------------------
    // USER3: control port. Bits 4 5 6 9 10 12 are the FIFO's pins and 26 is DIO0 (owned by other logic now): they are
    // kept as internal-only bits so the host's bit numbering stays the same. Overrides: bit 3 (N6) is held low during
    // FIFO sessions, bit 7 (P3) is the EEPROM clock while a read runs.
    // ---------------------------------------------------------------------------------------------------------------
    reg  [31:0] port_out = 32'h0815FF79, port_oe = 32'hDB17C00F;
    wire [31:0] port_in;
    reg  [63:0] sr3 = 64'h0;
    always @(posedge tck) begin
        if (sel3 && capture) sr3 <= {port_oe, port_in};
        else if (sel3 && shift) sr3 <= {tdi, sr3[63:1]};
        if (sel3 && update) begin port_out <= sr3[31:0]; port_oe <= sr3[63:32]; end
    end
    assign tdo3 = sr3[0];
    generate for (i = 0; i < 32; i = i + 1) begin : g_port
        if (i == 4 || i == 5 || i == 6 || i == 9 || i == 10 || i == 12 || i == 26) begin : internal
            assign port_in[i] = port_out[i];
        end else begin : pad
            localparam integer P = i - (i > 4) - (i > 5) - (i > 6) - (i > 9) - (i > 10) - (i > 12) - (i > 26);
            wire ovr_ee = (i == 7) && ee_busy;         // P3 = EEPROM CLK
            wire ovr_n6 = (i == 3) && fifo_alive;      // N6 low: JTAG buffers off, D0-D3 free for FIFO data
            IOBUF b (.IO(port_pad[P]), .I(ovr_ee ? ee_clk : ovr_n6 ? 1'b0 : port_out[i]),
                     .T(ovr_ee || ovr_n6 ? 1'b0 : ~port_oe[i]), .O(port_in[i]));
        end
    end endgenerate

    // ---------------------------------------------------------------------------------------------------------------
    // USER4: capture header read-out, AWG and pattern memory load
    // ---------------------------------------------------------------------------------------------------------------
    reg  [31:0] sr4 = 32'h0, li = 32'h0;              // shift-out header, shift-in word
    reg  [4:0]  bc = 5'h0;                             // bit count within the word
    reg  [12:0] lad = 13'h1fff;                        // load address (the first word goes to 8191 and is a dummy)
    wire        word_in = sel4 && shift && bc == 5'h1f;   // the 32nd bit of a word: li holds bits 0..30 shifted by one
    always @(posedge tck) begin
        if (sel4 && capture) begin sr4 <= {SIG_STATUS, trg, tph, 9'b0, tpos}; bc <= 5'h0; lad <= 13'h1fff; end
        else if (sel4 && shift) begin
            bc <= bc + 5'h1;
            li <= {tdi, li[31:1]};
            if (bc == 5'h1f) begin
                sr4 <= 32'h0;
                if (acfg[1] || pg_load) lad <= lad + 13'h1;
            end
            else sr4 <= {tdi, sr4[31:1]};
        end
    end
    assign tdo4 = sr4[0];
    // the word being completed is {tdi, li[31:1]}: AWG {B[29:16], A[13:0]}, pattern [15:0]

    // ---------------------------------------------------------------------------------------------------------------
    // Modules
    // ---------------------------------------------------------------------------------------------------------------
    adf4360_spi u_pll (
        .clk12(clk12), .tck(tck), .sel(sel1), .capture(capture), .shift(shift), .update(update), .tdi(tdi), .tdo(tdo1),
        .lock_detect(clkd_ld), .le(clkd_le), .sclk(clkd_sclk), .sdata(clkd_sdio));

    microwire_reader u_ee (
        .clk12(clk12), .start(ee_start), .addr(ee_addr), .busy(ee_busy), .data(ee_word),
        .ee_cs(ee_cs), .ee_clk(ee_clk), .ee_dio(ee_dio));

    wire        rd_clk;
    wire [12:0] rd_addr, rd_addr_gray, wr_addr_gray;
    wire [31:0] rd_data;
    wire [15:0] la_rise, la_fall;
    scope_capture u_cap (
        .clk100(clk100), .adc_rise(adc_rise), .adc_fall(adc_fall), .la_rise(la_rise), .la_fall(la_fall),
        .dec(dec), .pre(pre), .cont(cont), .la(la), .la200(la200), .smode(smode), .avk(avk),
        .lvl(lvl), .tlo(tlo), .thi(thi), .tsrc(tsrc), .tslope(tslope), .ten(ten),
        .lmask(lmask), .lval(lval), .lch(lch), .ledge(ledge), .lpol(lpol), .ext_trig(csrc != 3'd0 && csrc != 3'd5), .dio_trig(csrc == 3'd5), .xev(xev),
        .arm_t(arm_t), .force_t(force_t), .stop_t(stop_t),
        .run(run), .done(done), .trg(trg), .tph(tph), .stg(stg), .tpos(tpos), .capev(capev),
        .done_t(done_t), .cont_t(cont_t), .avg(avg),
        .rd_clk(rd_clk), .rd_addr(rd_addr), .rd_data(rd_data), .rd_addr_gray(rd_addr_gray), .wr_addr_gray(wr_addr_gray));

    dio_pattern u_dio (
        .clk100(clk100), .dio(dio), .trig(trig), .la_rise(la_rise), .la_fall(la_fall), .pins(dio_pins),
        .dio_out(dio_out), .dio_oe(dio_oe), .tp_count(tp_count), .tp_square(tp_square),
        .pg_run(pg_run), .pg_once(pg_once), .pg_last(pg_last), .pg_div(pg_div),
        .pg_wclk(tck), .pg_we(word_in && pg_load), .pg_waddr(lad[10:0]), .pg_wdata(li[16:1]),
        .csrc(csrc), .cpol(cpol), .asrc(asrc), .psrc(psrc), .t1o(t1o), .t2o(t2o),
        .capev(capev), .awg_ev_t(awg_ev_t), .xev(xev), .awg_start_t(awg_start_t));

    awg_player u_awg (
        .clk12(clk12), .clk_in(adc_clk_b), .acfg(acfg[5:2]), .last(alast),
        .ftw_t(ftw_t), .dds_t(dds_t), .ftw_tog(ftw_tog), .asrc(asrc), .start_t(awg_start_t),
        .mem_wclk(tck), .mem_we(word_in && acfg[1]), .mem_waddr(lad), .mem_wdata({li[30:17], li[14:1]}),
        .dac_d(awg_d), .dac_clk(awg_clkio), .locked(awg_locked), .ev_t(awg_ev_t));

    freq_counter u_fc (
        .clk100(clk100), .adc_rise(adc_rise), .adc_fall(adc_fall), .dio(la_rise),
        .run(fc_run), .src(fc_src), .level(fc_level), .low(fc_low), .gate(fc_gate),
        .seq(fc_seq), .periods(fc_periods), .cycles(fc_cycles), .first(fc_first), .last(fc_last));

    usb_fifo u_usb (
        .clk12(clk12), .ft_clk(ft_clk), .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n),
        .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_oe_n(ft_oe_n), .ft_siwu_n(ft_siwu_n), .ft_d(ft_d),
        .alive(fifo_alive), .locked(fifo_locked),
        .cmd_word(fword), .cmd_t(fword_t), .cmd_ack(fword_ack),
        .rd_clk(rd_clk), .rd_addr(rd_addr), .rd_data(rd_data), .rd_addr_gray(rd_addr_gray), .wr_addr_gray(wr_addr_gray),
        .done_t(done_t), .cont_t(cont_t), .trg(trg), .tph(tph), .tpos(tpos), .pre(pre), .la(la), .avg(avg),
        .overflow(fifo_overflow));
endmodule
`default_nettype wire
