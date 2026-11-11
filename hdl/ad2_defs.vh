// Shared definitions of the AD2 design, included inside the modules that need them.

// USER2 command codes: bits [55:48] of the 56-bit command word (JTAG USER2 or a FIFO command packet).
localparam [7:0] CMD_ARM       = 8'h5A;   // [0] arm a capture, [1] force the trigger, [2] stop continuous streaming
localparam [7:0] CMD_AWG       = 8'h5B;   // generator config: [1] memory load, [2] play, [3] invert DCLKIO, [4] swap A/B,
                                          // [5] DCM reset, [28:16] last playback address
localparam [7:0] CMD_GAIN      = 8'h5C;   // [3:0] scope input switches {EN_HG_SC1, EN_LG_SC1, EN_HG_SC2, EN_LG_SC2}
localparam [7:0] CMD_CAPTURE   = 8'h5D;   // [23:0] decimation, [36:24] pre-trigger, [37] continuous, [38] logic analyser,
                                          // [39] LA 200 MS/s, [41:40] sampling mode, [46:42] averaging log2(N)
localparam [7:0] CMD_TRIGGER   = 8'h5E;   // [13:0] level, [27:14] hysteresis, [28] source CH2, [29] falling, [30] enable
localparam [7:0] CMD_DIO       = 8'h60;   // [15:0] static outputs, [31:16] output enables
localparam [7:0] CMD_LA_TRIG   = 8'h61;   // [15:0] mask, [31:16] value, [35:32] edge channel, [36] edge on, [37] falling
localparam [7:0] CMD_PINS      = 8'h62;   // the next USER2 capture returns {SIG_PINS, DIO pins}
localparam [7:0] CMD_TESTPAT   = 8'h63;   // [0] DIO counter pattern, [1] DIO 100 MHz square
localparam [7:0] CMD_PG        = 8'h64;   // pattern generator: [0] run, [1] memory load, [2] once, [26:16] last address
localparam [7:0] CMD_PG_RATE   = 8'h65;   // [23:0] pattern generator divider: rate = 100 MHz / (div + 1)
localparam [7:0] CMD_SUPPLIES  = 8'h66;   // [1:0] user supply enables {EN_PWR_USR, N5}
localparam [7:0] CMD_XTRIG     = 8'h67;   // cross-trigger routing, see dio_pattern.v (capture source 5: DIO in scope mode)
localparam [7:0] CMD_DDS       = 8'h68;   // [31:0] DDS frequency tuning word, [32] DDS on
localparam [7:0] CMD_EEPROM    = 8'h69;   // [7:0] word address: read one calibration EEPROM word

// Signatures in the top byte of the read-back words.
localparam [7:0] SIG_STATUS    = 8'hA5;   // USER1/USER2 status, USER4 header, FIFO snapshot header
localparam [7:0] SIG_PINS      = 8'hA6;   // USER2 after CMD_PINS
localparam [7:0] SIG_EEPROM    = 8'hA7;   // USER2 after CMD_EEPROM

// Host -> FPGA FIFO byte that starts a command packet (followed by the 7 bytes of a command word, low byte first).
localparam [7:0] FIFO_CMD      = 8'h80;

// 13-bit Gray code to binary (used for memory addresses crossing between clock domains).
function [12:0] gray2bin;
    input [12:0] g;
    integer k;
    begin
        gray2bin[12] = g[12];
        for (k = 11; k >= 0; k = k - 1) gray2bin[k] = gray2bin[k + 1] ^ g[k];
    end
endfunction
