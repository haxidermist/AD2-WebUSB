// FT232H synchronous 245 FIFO (60 MHz): command packets from the host and capture data to the host.
//
// Clock: the FT232H drives CLKOUT only while a FIFO session is open. A watchdog in the 12 MHz domain sees whether the
// clock runs (`alive`), keeps the deskew DCM in reset while it does not, and retries the DCM if it fails to lock. While
// `alive` the top level holds N6 low: N6 is the FT232H's ACBUS7 and enables the buffers between ADBUS0-3 and the
// FPGA's JTAG pins, so with it low D0-D3 are plain data lines (D2 on N12) and data cannot disturb the JTAG port.
// The data bus is released whenever the clock stops, so an ended session never leaves the FPGA driving it.
//
// Host -> FPGA bytes
//   FIFO_CMD (0x80) + 7 bytes   a command word, low byte first, executed by the decoder in the top level as if it had
//                               been written over JTAG USER2; no more bytes are taken until the decoder has it
//   any other byte              grants 512 bytes of reply
//   An arm command (CMD_ARM bit 0) clears the grant count and stops the reader, so the host sends its commands, the
//   arm, then the grants for the whole snapshot, and only the new snapshot follows, as soon as the capture is done.
//
// FPGA -> host bytes: memory words, 4 bytes each, low byte first.
//   snapshot    after every finished capture: a header word {SIG_STATUS, triggered, half, 9'b0, tpos}, then 8192 words
//               from tpos - pre (time order)
//   continuous  the reader follows the capture ring writer until it is stopped
// Scope words go out as {2'b0, flags[1:0], CH2[13:0], CH1[13:0]}, LA and average words as stored. The reader sets
// `overflow` when a continuous scope word carries the gap flag.
`default_nettype none
module usb_fifo (
    input  wire        clk12,
    // FT232H
    input  wire        ft_clk, input wire ft_rxf_n, input wire ft_txe_n,
    output wire        ft_rd_n, output wire ft_wr_n, output wire ft_oe_n, output wire ft_siwu_n,
    inout  wire [7:0]  ft_d,
    output reg         alive = 1'b0,                  // CLKOUT is running (12 MHz domain)
    output wire        locked,                        // deskew DCM locked
    // command packets to the decoder (handshake: cmd_t toggles, the decoder copies it to cmd_ack)
    output reg  [55:0] cmd_word = 56'h0, output reg cmd_t = 1'b0, input wire cmd_ack,
    // capture memory and engine
    output wire        rd_clk, output reg [12:0] rd_addr = 13'h0, input wire [31:0] rd_data,
    output reg  [12:0] rd_addr_gray = 13'h0, input wire [12:0] wr_addr_gray,
    input  wire        done_t, input wire cont_t,     // snapshot ready / continuous start (toggles)
    input  wire        trg, input wire tph, input wire [12:0] tpos, input wire [12:0] pre,
    input  wire        la, input wire avg,
    output reg         overflow = 1'b0
);
    `include "ad2_defs.vh"

    // ---- clock, DCM and watchdog ----
    wire c_in, c0, uclk, dcm_locked;
    IBUFG b_clk (.I(ft_clk), .O(c_in));
    reg  dcm_rst = 1'b1;
    DCM_SP #(.CLKIN_PERIOD(16.667), .CLK_FEEDBACK("1X"), .DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"))
        dcm (.CLKIN(c_in), .CLKFB(uclk), .RST(dcm_rst), .CLK0(c0), .LOCKED(dcm_locked),
             .CLK90(), .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(), .CLKDV(), .CLKFX(), .CLKFX180(), .STATUS(),
             .DSSEN(1'b0), .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE());
    BUFG b_uclk (.I(c0), .O(uclk));
    assign locked = dcm_locked; assign rd_clk = uclk;

    reg  [5:0]  tgl = 6'h0;                            // divided raw clock, sampled at 12 MHz to see if it runs
    always @(posedge c_in) tgl <= tgl + 6'h1;
    reg  [2:0]  uts = 3'b0;
    reg  [7:0]  uidle = 8'hff;                         // 12 MHz cycles since the last edge of tgl[5]
    reg  [15:0] uwd = 16'h0;
    reg  [1:0]  ulk = 2'b0;
    always @(posedge clk12) begin
        uts <= {uts[1:0], tgl[5]}; ulk <= {ulk[0], dcm_locked};
        if (uts[2] != uts[1]) uidle <= 8'h0; else if (uidle != 8'hff) uidle <= uidle + 8'h1;
        alive <= (uidle <= 8'd12);
        if (uidle > 8'd24) begin dcm_rst <= 1'b1; uwd <= 16'h0; end                               // no clock: hold reset
        else if (dcm_rst) begin uwd <= uwd + 16'h1; if (uwd == 16'd120) dcm_rst <= 1'b0; end      // clock back: 10 us reset
        else if (!ulk[1]) begin uwd <= uwd + 16'h1; if (uwd == 16'd24000) begin dcm_rst <= 1'b1; uwd <= 16'h0; end end   // 2 ms unlocked: retry
        else uwd <= 16'd120;
    end

    // ---- pads (IOB registers for the 8 ns FT232H setup time) ----
    (* IOB = "TRUE" *) reg rxf_q = 1'b1, txe_q = 1'b1;
    (* IOB = "TRUE" *) reg [7:0] dout = 8'h0;
    (* IOB = "TRUE" *) reg [7:0] din = 8'h0;
    (* IOB = "TRUE" *) reg rd_p = 1'b1, wr_p = 1'b1, oe_p = 1'b1;
    reg  rd_i = 1'b1, wr_i = 1'b1, den = 1'b0;        // internal copies of RD#/WR#, data output enable
    assign ft_d = (den && alive) ? dout : 8'bz;
    assign ft_rd_n = rd_p; assign ft_wr_n = wr_p; assign ft_oe_n = oe_p;
    assign ft_siwu_n = 1'b1;

    // ---- byte handshakes ----
    reg  rd_prev = 1'b1, wr_prev = 1'b1;
    wire acc = !wr_prev && !txe_q;                    // the byte presented two edges ago was taken
    wire got = !rd_prev && !rxf_q;                    // a host byte was read at the last edge (it is in din)

    // ---- command parser ----
    // One more byte may already be in flight when a packet completes: it waits in `hold` while the command is pending
    // (cpend: not yet acknowledged by the decoder).
    reg  [2:0]  cn = 3'd0;                             // command bytes still to come
    reg  [55:0] cbuf = 56'h0;
    reg         hv = 1'b0;                             // hold is valid
    reg  [7:0]  hold = 8'h0;
    reg  [1:0]  ack_s = 2'b0;
    wire        cpend = cmd_t != ack_s[1];
    wire        pgot = hv ? !cpend : got && !cpend;    // a host byte to parse now (the held one first)
    wire [7:0]  pb = hv ? hold : din;
    wire        grant = pgot && cn == 3'd0 && !pb[7];
    wire        cdone = pgot && cn == 3'd1;            // last byte of a command packet
    wire [55:0] cword = {pb, cbuf[55:8]};
    wire        rstop = cpend || hv || cdone;          // stop reading host bytes

    // ---- reader ----
    reg  [13:0] urem = 14'h0;                          // snapshot words left
    reg         ucont = 1'b0;                          // following the continuous ring
    reg         hdr = 1'b0;                            // next word is the snapshot header
    reg         ula = 1'b0, uavg = 1'b0;
    reg  [35:0] wb = 36'h0;                            // word being sent
    localparam [2:0] NLAST = 3'd3;                     // index of the last byte of a word
    reg  [2:0]  si = NLAST;                            // last byte of wb sent (NLAST: word used up)
    reg  [12:0] wg1 = 13'h0, wg2 = 13'h0;
    wire [12:0] wa = gray2bin(wg2);                    // capture writer address (continuous mode)
    reg  [2:0]  cds = 3'b0, css = 3'b0;
    reg  [1:0]  ulks = 2'b0;
    reg  [23:0] quota = 24'h0;                         // granted reply bytes
    wire [35:0] mqp = hdr ? {4'h0, SIG_STATUS, trg, tph, 9'b0, tpos}
                    : (ula || uavg) ? {4'h0, rd_data} : {6'h0, rd_data[31:30], rd_data[29:16], rd_data[13:0]};
    wire        take = acc && si == NLAST;             // the next word is being started
    wire [2:0]  si_n = acc ? (si == NLAST ? 3'd0 : si + 3'd1) : si;
    wire [35:0] wb_n = take ? mqp : wb;
    wire [12:0] ra_n = take && !hdr ? rd_addr + 13'h1 : rd_addr;
    wire [13:0] urem_n = take && !hdr ? urem - 14'h1 : urem;
    wire        arm_cmd = cdone && cword[55:48] == CMD_ARM && cword[0];   // the host armed a capture
    wire [23:0] quota_n = arm_cmd ? 24'h0
                        : quota + (grant ? 24'd512 : 24'd0) - (acc ? 24'd1 : 24'd0);
    wire        wordok_n = ucont ? (wa != ra_n) : (urem_n != 14'h0);
    wire        byteok_n = (si_n != NLAST) || wordok_n;   // there is a byte to send
    reg  [7:0]  nbyte;                                 // the byte after si_n: the next word's byte 0 once si_n = NLAST
    always @* case (si_n)
        3'd0: nbyte = wb_n[15:8]; 3'd1: nbyte = wb_n[23:16]; 3'd2: nbyte = wb_n[31:24];
        default: nbyte = mqp[7:0];
    endcase

    // ---- bus state machine ----
    localparam [1:0] S_IDLE = 2'd0, S_READ = 2'd1, S_TURN = 2'd2, S_WRITE = 2'd3;
    reg  [1:0]  us = S_IDLE;
    reg         ph = 1'b0;                             // write: second clock of a byte
    always @(posedge uclk) begin
        rxf_q <= ft_rxf_n; txe_q <= ft_txe_n; din <= ft_d; ack_s <= {ack_s[0], cmd_ack};
        // command parser
        if (got && cpend) begin hold <= din; hv <= 1'b1; end
        else if (hv && !cpend) hv <= 1'b0;
        if (pgot) begin
            if (cn == 3'd0) begin if (pb[7]) cn <= 3'd7; end
            else begin cbuf <= cword; cn <= cn - 3'd1; if (cn == 3'd1) begin cmd_word <= cword; cmd_t <= ~cmd_t; end end
        end
        // reader
        if (take) hdr <= 1'b0;
        rd_prev <= rd_i; wr_prev <= wr_i;
        wg1 <= wr_addr_gray; wg2 <= wg1; rd_addr_gray <= ra_n ^ (ra_n >> 1);
        cds <= {cds[1:0], done_t}; css <= {css[1:0], cont_t}; ulks <= {ulks[0], dcm_locked};
        si <= si_n; wb <= wb_n; rd_addr <= ra_n; urem <= urem_n; quota <= quota_n;
        if (take && !hdr && rd_data[30] && !ula && !uavg) overflow <= 1'b1;
        ula <= la; uavg <= avg;
        // an arm also ends whatever the reader was doing (continuous streaming, the unread rest of an aborted
        // snapshot), so the grants that follow release only the new snapshot
        if (arm_cmd) begin urem <= 14'h0; ucont <= 1'b0; si <= NLAST; hdr <= 1'b0; end
        if (cds[2] != cds[1]) begin rd_addr <= tpos - pre; urem <= 14'h2000; ucont <= 1'b0; si <= NLAST; hdr <= 1'b1; end
        if (css[2] != css[1]) begin rd_addr <= 13'h0; urem <= 14'h0; ucont <= 1'b1; si <= NLAST; quota <= 24'h0; overflow <= 1'b0; end
        // bus
        if (!ulks[1]) begin                            // DCM not locked yet (session start): idle
            us <= S_IDLE; rd_i <= 1'b1; rd_p <= 1'b1; wr_i <= 1'b1; wr_p <= 1'b1; oe_p <= 1'b1; den <= 1'b0; ph <= 1'b0;
            cn <= 3'd0; hv <= 1'b0;                     // no half packet left over from an earlier session
        end else case (us)
        S_IDLE: begin
            rd_i <= 1'b1; rd_p <= 1'b1; wr_i <= 1'b1; wr_p <= 1'b1; den <= 1'b0; ph <= 1'b0;
            if (!rxf_q && !cpend && !hv) begin oe_p <= 1'b0; us <= S_READ; end
            else if (!txe_q && byteok_n && quota_n != 24'h0 && wr_prev) begin oe_p <= 1'b1; us <= S_WRITE; den <= 1'b1; end
        end
        S_READ: begin                                  // OE# low, then RD# low while host bytes remain
            if (rxf_q || rstop) begin rd_i <= 1'b1; rd_p <= 1'b1; oe_p <= 1'b1; us <= S_TURN; end
            else begin rd_i <= 1'b0; rd_p <= 1'b0; end
        end
        S_TURN: us <= S_IDLE;                          // bus turnaround
        S_WRITE: begin                                 // two clocks per byte: present, then wait for TXE# at the sample edge
            if (ph) begin wr_i <= 1'b1; wr_p <= 1'b1; ph <= 1'b0; end
            else if (txe_q || !byteok_n || quota_n == 24'h0) begin wr_i <= 1'b1; wr_p <= 1'b1; us <= S_IDLE; end
            else begin wr_i <= 1'b0; wr_p <= 1'b0; ph <= 1'b1; dout <= nbyte; end
        end
        endcase
    end
endmodule
`default_nettype wire
