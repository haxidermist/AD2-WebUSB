# AD2 WebUSB

A browser instrument panel for the Digilent Analog Discovery 2: oscilloscope, spectrum analyser, waveform
generator, power supplies, logic analyser and digital outputs. It runs entirely in Chrome over WebUSB and loads
its own FPGA design into the board. No WaveForms, no Adept, no drivers to install, no server.

This is an independent project. It is not made, supported or endorsed by Digilent. Analog Discovery is a
trademark of Digilent.

## Quick start

1. Download `ad2.html` (and `detach.py` on Linux).
2. Plug in the Analog Discovery 2. On Linux, run `python3 detach.py` (see below).
3. Open `ad2.html` in Chrome or another Chromium browser. Double-clicking the file is fine.
4. Click **Connect** and choose "Digilent USB Device".

The page loads its FPGA design if the board is blank, initialises the clocks and converters, reads the board's
calibration from its EEPROM and shows "ready", usually within a couple of seconds.

## Requirements

- **Browser:** Chrome, Edge or another Chromium browser with WebUSB. Firefox and Safari have no WebUSB.
- **Linux:** tested. After every plug-in, the kernel's `ftdi_sio` serial driver claims the board, and the
  browser then cannot open it ("Unable to claim interface"). Run `python3 detach.py` to release it. It needs
  only Python 3 and libusb-1.0, runs as a normal user (with the same USB access WaveForms needs), and changes
  nothing permanently. Without it, Connect fails.
- **Windows and macOS:** not tested. On Windows the Digilent/FTDI driver normally owns the device, and WebUSB
  would need the WinUSB driver instead (which in turn stops WaveForms from seeing the board).
- Close WaveForms and any other tab using the board first: only one program can hold it at a time.

## What it does

| Instrument | Details |
|---|---|
| Oscilloscope | 2 channels, 14-bit, 10 kS/s to 100 MS/s, 8192 samples. 1 mV/div to 5 V/div with offset; the two hardware input ranges (±2.7 V and ±25 V) are picked automatically. Edge trigger on CH1 or CH2 with auto timeout. Trigger-aligned averaging. |
| Spectrum analyser | 8192-point FFT of both channels in dBV. Blackman-Harris, Hann, flat-top or rectangular window; live, averaged or max-hold trace; linear or log frequency axis; peak marker. |
| Waveform generator | W1 and W2: sine, square, triangle, sawtooth, sinc (1 to 100 lobes) and PRBS spread-spectrum (order 3 to 12), 1 Hz to 10 MHz, amplitude to 5 V, W2 phase offset. |
| Power supplies | V+ and V− 0.5 to 5 V, on/off, USB or external power mode. Monitors show the USB and AUX input voltage and current and the board temperature. |
| Logic analyser | 16 channels (DIO 0–15, view 8 or 16), selectable rate, pattern trigger with optional edge, zoom. |
| Digital outputs | Static levels with per-pin output enable, a counter pattern on chosen pins, pin readback. |

There are also self-tests: averaging (needs W2 wired to CH2) and the logic analyser (uses DIO 0–7).

## Using the panel

All controls are tiles in the side panel, grouped like the front of a bench oscilloscope. Clicking a tile
selects it. Use the slider, the −/+ buttons, or type an exact value: SI suffixes such as `2.5k`, `10m` or
`1M` work, and bit tiles take hex. Toggle tiles switch on a click, cycle tiles step through their options.
The **ⓘ** button in the top bar shows help for each tile on mouse-over. The panel can be hidden or moved to
the other side. Settings are remembered in the browser.

## Notes and limits

- **Supply current:** on USB power the supplies have a fixed limit of roughly 1 W in total and trip above it.
  Use an external supply on the AUX input for more.
- **Inputs:** the scope inputs take ±25 V at most. The digital pins are 3.3 V logic.
- **Not yet tested on hardware:** the ±25 V range, and the scope trigger, V− and external power mode in this page.
  Treat their readings with care until checked against a known reference.
- The page replaces the FPGA design WaveForms uses. WaveForms reloads its own the next time it opens the board,
  so nothing on the board is changed permanently. The calibration EEPROM is only read, never written.
- Known artefacts: small spurs at 20 and 40 MHz in the spectrum, and some crosstalk from the waveform
  generator into the scope inputs.

## Files

| File | Purpose |
|---|---|
| `ad2.html` | The whole application: page, USB driver and FPGA design in one file. |
| `detach.py` | Linux helper that releases the board from the kernel serial driver. |
| `LICENSE` | MIT licence. |
