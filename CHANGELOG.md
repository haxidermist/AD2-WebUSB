# Change log

Notable changes to the app (`ad2.html`) and its FPGA design (`hdl/`), newest first.

## 2026-11-11

- **New scope trigger sources:** AWG (the start of each waveform-generator period, so the trace locks to W1/W2
  whatever their shape or level) and DIO 0-15 (a rising or falling edge on that pin). The FPGA's DIO edge
  detector, used by the logic analyser, can now also trigger the scope (cross-trigger source 5); a DIO trigger
  lands about 10 ns late relative to the analog data.
- README feature overview updated: trigger sources and update rate.
- **Average without a trigger:** in Spectrum view, Average now power-averages the spectra over the Average count
  when no trigger is set (it used to do nothing there); with a trigger it vector-averages as before. The
  Average tile and the spectrum info line say which is active. It is now the only averaging control: the
  Spectrum group's Trace has just live and max hold, and its separate average count is gone.
- **Zoom by dragging:** drag across empty spectrum to select a band; it becomes the new Centre and Span.
  Right-click on empty spectrum steps back through earlier zooms; the Full span tile returns to the whole band.
  A plain click still shows a marker, and dragging a marker still moves it.
- **Spectrum markers, slots:** markers are now eight slots, M1-M8. The marker controls act on the selected
  one (step through with the Marker tile or keys 1-8): show / hide, trace, peak hopping, Track peak (follows
  the highest peak each capture) and Reading: live, max hold, min hold or average over captures, independent
  of the trace mode. Clicking empty spectrum shows the next hidden marker; right-click hides one.
- **Spectrum markers:** up to 8, each on CH1 or CH2. Click the spectrum to add or select one, drag to move it,
  right-click to delete it. Peak hopping (Peak, ◀ Peak, Peak ▶ tiles; Home, ←, → keys) jumps between real
  peaks, skipping noise and window skirts, and refines each to the peak's exact frequency. A table under the
  plot lists the markers with Δf and Δ level to marker 1.
  The automatic peak markers (one per channel, switched by the Peak marker tile) are now drawn hollow and
  labelled "pk", so they are not mistaken for numbered markers left after Clear markers.
- **Frequency counter:** a reciprocal counter in the FPGA on CH1, CH2 (with interpolated crossings) or any DIO
  pin, gate 10 ms to 10 s. Checked against the generator, which runs on the same clock: a 1 MHz sine reads to
  within 0.01 ppb with 2.6 ppb scatter (0.1 s gate), DIO squares up to 25 MHz count exactly. The display
  shows as many digits as the measured scatter supports.
  Click the reading to switch between frequency and period (remembered).
  The reading is in scientific notation, with the digits after the point grouped in threes and the 1 Hz
  digit highlighted.
- **Spectrum centre frequency:** a Centre control next to Span. The band shown is centre ± span/2, kept within
  0 Hz and half the sample rate; the −/+ buttons move it by a tenth of the span. Centre 0 shows the band from
  0 Hz as before.

## 2026-11-10

- README: Windows needs the WinUSB driver for the board, installed once with Zadig (tested) or Windows' own
  WinUsb Device driver in Device Manager; how to switch it back for WaveForms. The app's connect error now points Windows users to it.

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

### Spectrum and trigger
- **Vector averaging:** in Spectrum view with a trigger and Average on, the spectrum is computed from the
  trigger-aligned waveform average. With 64 averages the noise floor of a test signal dropped from -93 to
  -116 dBV, and its harmonics became visible.
- Otherwise the spectrum runs free instead of waiting for a trigger (about 44 updates/s at 1 MS/s, was
  4-5 with no trigger signal).
- The auto-trigger timeout follows the timebase: twice the record length, at least 50 ms (was a fixed
  200 ms), so the scope with no trigger signal updates about twice as fast at short timebases.
- The scope view no longer computes the hidden spectrum, so it updates faster.
- Reconnecting after a page was closed or reloaded during a run could fail with "MPSSE sync failed".

### Reset settings
- A **↺ Reset** button next to Connect resets all remembered settings to their defaults and reloads the
  page. Settings are stored per copy of the page, so the hosted app and a downloaded file can differ.

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
