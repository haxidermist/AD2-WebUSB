# FPGA design

The Verilog source of the FPGA design the app loads into the Analog Discovery 2. `ad2.html` carries this
design's bitstream, built from these files, so you only need them to study or change the design.

## Files

| File | Purpose |
|---|---|
| `ad2_top.v` | Top level: pins, clocks, the JTAG user registers, the command decoder, the control port and the memory loader. Its header describes the whole host interface. |
| `scope_capture.v` | Capture engine shared by the oscilloscope and the logic analyser: sampling modes, trigger, capture memory. |
| `dio_pattern.v` | The 16 DIO pins, the pattern generator, the DIO test patterns and the cross-trigger routing (T1/T2). |
| `awg_player.v` | Waveform generator: playback memory, DDS, AD9717 DAC outputs. |
| `usb_fifo.v` | FT232H synchronous FIFO: clock watchdog, command packets, data to the host. |
| `adf4360_spi.v` | ADF4360 clock synthesiser register writer (JTAG USER1). |
| `microwire_reader.v` | Calibration EEPROM (93LC66B) reader. |
| `ad2_defs.vh` | Shared definitions: command codes, signatures, a Gray-code helper. |
| `ad2_top.ucf` | Pin map, grouped by function with the board's net names, plus the timing constraints. |
| `build.sh` | Builds `build/ad2.bit` with Xilinx ISE 14.7. |

Each module starts with a comment block describing its interface, data formats and timing.

## Overview

- **Host interface:** the host controls the design through the FPGA's own JTAG port (the FT232H in MPSSE mode),
  using the `BSCAN_SPARTAN6` user registers. USER1 writes the ADF4360 clock synthesiser, USER2 is the command and
  status register, USER3 drives a 32-bit control port for slow bit-banged I/O (SPI and I2C to the analog chips,
  supply enables), and USER4 loads the waveform and pattern memories.
- **Fast data path:** the FT232H synchronous FIFO (60 MHz) carries command packets to the FPGA and capture data
  to the host, 4 bytes per memory word. On the AD2, FIFO data lines D0-D3 are shared with the FT232H's JTAG lines
  through buffers enabled by pin N6 (the FT232H's ACBUS7). The design holds N6 low while the FIFO clock runs,
  which frees D0-D3 for data (D2 is on N12), and releases it afterwards so JTAG works again. Thanks to
  [nic3-14159/AD2_RE](https://github.com/nic3-14159/AD2_RE) for that pin information.
- **Scope:** the dual 14-bit ADC sampled on both edges of the 100 MHz clock, an 8192-sample capture memory,
  decimation and pre-trigger, an edge trigger with hysteresis on either channel, and averaging and min/max modes.
- **Waveform generator:** an 8192-point playback memory per channel and a DDS phase accumulator, driving the
  AD9717 dual DAC.
- **Logic analyser and digital I/O:** 16-channel capture at up to 200 MS/s with a pattern and edge trigger,
  static outputs, a pattern generator, and cross-triggering between the instruments and the T1/T2 pins.
- **Board control:** the scope gain switches, supply enables, and the calibration EEPROM reader.

## Commands

Commands are 56-bit words whose top byte selects the function. They can be written over JTAG (USER2) or sent
through the USB FIFO as an 8-byte packet (`0x80` followed by the 7 bytes of the word, low byte first), so the app
can capture without leaving FIFO mode. Any other byte the host sends grants 512 bytes of reply. An arm command
clears the grant count and resets the reader, and after each capture the FPGA sends a header word, then the
8192-word snapshot. The commands are decoded in the FPGA's 12 MHz clock domain, so a JTAG write should be
followed by a few idle TCKs before the next scan that depends on it (the app clocks 16).

| Code | Name in `ad2_defs.vh` | Function |
|---|---|---|
| `5A` | `CMD_ARM` | arm a capture, force the trigger, stop continuous streaming |
| `5B` | `CMD_AWG` | waveform generator configuration |
| `5C` | `CMD_GAIN` | scope gain switches |
| `5D` | `CMD_CAPTURE` | decimation, pre-trigger, continuous, logic-analyser mode, averaging and min/max |
| `5E` | `CMD_TRIGGER` | scope trigger |
| `60` | `CMD_DIO` | DIO outputs and output enables |
| `61` | `CMD_LA_TRIG` | logic-analyser trigger |
| `62` | `CMD_PINS` | read the DIO pins (next USER2 capture) |
| `63` | `CMD_TESTPAT` | DIO test patterns |
| `64`, `65` | `CMD_PG`, `CMD_PG_RATE` | pattern generator |
| `66` | `CMD_SUPPLIES` | user supply enables |
| `67` | `CMD_XTRIG` | cross-trigger routing and the T1/T2 pins; capture source 3 = AWG start, 5 = DIO pattern/edge in scope mode |
| `68` | `CMD_DDS` | DDS frequency |
| `69` | `CMD_EEPROM` | read a calibration EEPROM word (next USER2 capture) |

The status word reads back the signature `A5`, so the app can tell this design is loaded, and sets bits 47 and 46
to announce the 8-bit FIFO and the FIFO command packets. The app reloads its own design if any of them is missing.

## Building

1. Install Xilinx ISE 14.7 (the last ISE release, still available free from AMD/Xilinx as "ISE WebPACK").
2. Run `./build.sh`, or `./build.sh /path/to/ISE_DS/settings64.sh` if ISE is not under `/opt/Xilinx` or
   `/tools/Xilinx`.

The target part is `xc6slx16l-1L-cpg196`. The build takes a few minutes, writes `build/ad2.bit` and prints the
timing result. If a step fails, it names the log to read.

A build from these files reproduces the design embedded in `ad2.html`. PAR reports failing paths on one
constraint, `OFFSET = OUT` on the FIFO clock: the 8 FIFO data outputs are not packed into I/O-block registers,
so their clock-to-out is 11-13 ns against the 10 ns constraint, depending on placement. Every release has had
this and works on the board, but it is the first place to look if FIFO data glitches after a change.

## Known quirks

- **N5 (PWRGD_USR)** is an output of the ADM1270 supply controller, but the design drives it together with
  EN_PWR_USR, as WaveForms does. It has caused no problems, but the pin would be better used as an input.

## Trying a changed design

In the app's top bar, choose your `ad2.bit` with the file picker, then click **Program file**. The page loads it
over JTAG in place of the built-in design. The instrument tiles will only work if your design keeps the command
interface above, the `A5` signature and the FIFO format.

The design is for experimenting. It has been tested on one board, and a mistake in the pin map or the I/O
settings could drive a pin against the analog circuitry, so check changes to `ad2_top.ucf` carefully.
