# Change log

Notable changes to the app (`ad2.html`) and its FPGA design (`hdl/`), newest first.

## 2026-11-09

### Faster captures
- Commands now travel through the USB FIFO, so the board stays in FIFO mode between captures instead of
  switching the FT232H back to JTAG after every read. A 100 MS/s scope capture takes about 13 ms instead of
  about 135 ms, roughly 75 captures per second instead of 7. The logic analyser gains about as much.
- The FPGA sends each capture as soon as it finishes, preceded by a header word with the trigger flag and
  position, so the app no longer polls the capture status.
- Anything that still needs JTAG (supply monitors, generator, range and supply changes) switches back
  automatically, and the next capture returns to FIFO mode.

### Full 8-bit USB transfers
- The design holds pin N6 low during USB transfers. N6 enables the buffers that share data lines D0-D3
  with the FT232H's JTAG lines, so holding it low frees D0-D3 for data and D2 becomes usable (on pin N12).
  Each memory word now goes as 4 bytes instead of 5 (scope) or 6 (logic analyser) 6-bit symbols.
- Data on D0 can no longer disturb the FPGA's JTAG port during transfers.
- Thanks to [nic3-14159/AD2_RE](https://github.com/nic3-14159/AD2_RE) for the pin information that made
  this possible.

### Build label
- The top bar shows when the page was built, next to the name, so a cached older copy is easy to spot.

### Fixes
- The first capture after a continuous stream, or after a capture whose read was aborted, could fail with
  "bad FIFO header". Arming a capture now also resets the FPGA's FIFO reader.
- **Disconnect** works while the scope or the logic analyser is running: it stops the run, lets the last
  capture finish, then disconnects.

### FPGA source restructured
- The design in `hdl/` is split into one module per function (top level, capture engine, digital I/O and
  pattern generator, waveform generator, USB FIFO, PLL writer, EEPROM reader), each with a comment block
  describing its interface and data formats. Command codes have names, pins carry the board's net names, and
  `build.sh` builds all files and reports which step failed. Behaviour is unchanged apart from the fix above:
  every instrument feature was checked on the board against the previous build.

### Compatibility
- The design announces these features in its status word (bits 47 and 46). If the board still holds an
  earlier build of the design, the app reloads its own.
- Custom designs built from `hdl/` need the new FIFO format and command handling to work with the app; see
  [hdl/README.md](hdl/README.md).

## 2026-11-07

- First public release: the whole instrument panel in one file, `ad2.html` (oscilloscope, spectrum analyser,
  waveform generator, power supplies, logic analyser and digital outputs), hosted on GitHub Pages and
  usable offline.
- `detach.py` for Linux, which releases the board from the kernel's serial driver.
- README with a feature overview and screenshots from a real board; the page's log stays on the local
  machine.
- FPGA design source published in `hdl/`: Verilog, pin map and ISE build script. A build from it reproduces
  the design inside `ad2.html`.
- Pin map: H11 drives the green status LED.
