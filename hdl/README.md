# FPGA design ("build k")

The Verilog source of the FPGA design the app loads into the Analog Discovery 2. `ad2.html` carries this
design's bitstream, built from these files, so you only need them to study or change the design.

| File | Purpose |
|---|---|
| `top.v` | The whole design, one module using only Xilinx primitives. The comment block at the top documents the JTAG registers. |
| `top.ucf` | Pin map of the Spartan-6 on the AD2, worked out by probing the board, with the I/O standards. |
| `build.sh` | Builds `build/top.bit` with Xilinx ISE 14.7. |

## What it contains

- **Host interface:** everything is controlled over the FPGA's own JTAG port (the FT232H in MPSSE mode),
  through the `BSCAN_SPARTAN6` user registers. USER1 writes the ADF4360 clock synthesiser, USER2 is the
  control and status register, USER3 drives the 32-bit control port to the analog circuitry, and USER4 reads
  the capture memory or loads the AWG memory.
- **Fast data path:** the FT232H synchronous FIFO (60 MHz) streams scope and logic-analyser captures to the
  host, much faster than JTAG.
- **Scope:** the dual 14-bit ADC on both edges of the 100 MHz sample clock, an 8192-sample capture memory,
  decimation and pre-trigger, edge trigger with hysteresis on either channel, and averaging and min/max modes.
- **Waveform generator:** an 8192-point playback memory per channel and a DDS phase accumulator, driving the
  AD9717 dual DAC.
- **Logic analyser and digital I/O:** a 16-channel capture with pattern and edge trigger, static outputs, and
  a pattern generator.
- **Board control:** power supply enables, the scope gain switches, and a Microwire reader for the calibration
  EEPROM.

USER2 commands are selected by the top byte of the 56-bit data register. The app's driver uses:

| Code | Function |
|---|---|
| `5A` | start or arm a capture |
| `5B` | AWG configuration |
| `5C` | scope gain switches |
| `5D` | decimation, pre-trigger, logic-analyser mode, averaging |
| `5E` | scope trigger |
| `60` | DIO outputs and output enables |
| `61` | logic-analyser trigger |
| `62` | pin read |
| `63` | test pattern |
| `64`, `65` | pattern generator |
| `66` | supply enables |
| `67` | trigger pins T1/T2: cross-trigger routing |
| `68` | DDS frequency |
| `69` | calibration EEPROM (Microwire) |

The status word reads back the signature `A5`, so the app can tell this design is loaded.

## Building

1. Install Xilinx ISE 14.7 (the last ISE release, still available free from AMD/Xilinx as "ISE WebPACK").
2. Run `./build.sh`, or `./build.sh /path/to/ISE_DS/settings64.sh` if ISE is not under `/opt/Xilinx` or
   `/tools/Xilinx`.

The target part is `xc6slx16l-1L-cpg196`. The build takes a few minutes and writes `build/top.bit`.

A build from these files is identical to the design embedded in `ad2.html` (apart from the build date in
the file header). PAR reports a timing score of about 4750: some timing constraints are not met. The
shipped design has the same result and works on the board, but this is a place to look first if you see
glitches after changing the design.

## Trying a changed design

In the app's top bar, choose your `top.bit` with the file picker, then click **Program file**. The page loads it
over JTAG in place of the built-in design. The instrument tiles will only work if your design keeps the register interface above
and the `A5` signature.

The design is for experimenting. It has been tested on one board, and a mistake in the pin map or the I/O
settings could drive a pin against the analog circuitry, so check changes to `top.ucf` carefully.
