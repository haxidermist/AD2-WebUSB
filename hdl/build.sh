#!/bin/bash
# Build the FPGA design with Xilinx ISE 14.7: XST -> NGDBuild -> MAP -> PAR -> BitGen.
# Output: build/ad2.bit, the design the app embeds. Logs are in build/*.log.
# Usage: ./build.sh [path to ISE's settings64.sh]
set -e
SETTINGS=${1:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}
[ -f "$SETTINGS" ] || SETTINGS=/tools/Xilinx/14.7/ISE_DS/settings64.sh
[ -f "$SETTINGS" ] || { echo "ISE 14.7 settings64.sh not found: pass its path as the first argument" >&2; exit 1; }

SOURCES="ad2_top.v scope_capture.v dio_pattern.v awg_player.v usb_fifo.v adf4360_spi.v microwire_reader.v"
PART=xc6slx16l-1L-cpg196

cd "$(dirname "$0")"
mkdir -p build
cp $SOURCES ad2_defs.vh ad2_top.ucf build/
cd build
set --; source "$SETTINGS" >/dev/null 2>&1

for f in $SOURCES; do echo "verilog work $f"; done > ad2.prj
printf 'run\n-ifn ad2.prj\n-ifmt mixed\n-top ad2_top\n-ofn ad2.ngc\n-ofmt NGC\n-p %s\n-iobuf YES\n' $PART > ad2.xst

step() { echo "$1..."; shift; "$@" > "$LOG" 2>&1 || { echo "failed, see build/$LOG" >&2; exit 1; }; }
LOG=xst.log      step synthesis  xst -ifn ad2.xst -ofn ad2.syr
LOG=ngd.log      step translate  ngdbuild -p $PART -uc ad2_top.ucf ad2.ngc ad2.ngd
LOG=map.log      step map        map -p $PART -w -o ad2_map.ncd ad2.ngd ad2.pcf
LOG=par.log      step place      par -w ad2_map.ncd ad2.ncd ad2.pcf
LOG=bitgen.log   step bitstream  bitgen -w -g UnusedPin:PullNone -g StartUpClk:JtagClk ad2.ncd ad2.bit

grep -E 'Timing Score|All signals' par.log || true
ls -l ad2.bit
