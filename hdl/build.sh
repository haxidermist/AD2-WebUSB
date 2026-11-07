#!/bin/bash
# Build the FPGA design with Xilinx ISE 14.7: XST -> NGDBuild -> MAP -> PAR -> BitGen.
# Output: build/top.bit (the page embeds this as its "build k" design). Usage: ./build.sh [ISE settings64.sh]
set -e
SETTINGS=${1:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}
[ -f "$SETTINGS" ] || SETTINGS=/tools/Xilinx/14.7/ISE_DS/settings64.sh
[ -f "$SETTINGS" ] || { echo "ISE 14.7 settings64.sh not found: pass its path as the first argument" >&2; exit 1; }
cd "$(dirname "$0")"; mkdir -p build; cp top.v top.ucf build/; cd build
set -- ; source "$SETTINGS" >/dev/null 2>&1
P=xc6slx16l-1L-cpg196
echo "verilog work top.v" > top.prj
printf 'run\n-ifn top.prj\n-ifmt mixed\n-top top\n-ofn top.ngc\n-ofmt NGC\n-p %s\n-iobuf YES\n' $P > top.xst
xst -ifn top.xst -ofn top.syr > xst.log 2>&1
ngdbuild -p $P -uc top.ucf top.ngc top.ngd > ngd.log 2>&1
map -p $P -w -o top_map.ncd top.ngd top.pcf > map.log 2>&1
par -w top_map.ncd top.ncd top.pcf > par.log 2>&1
bitgen -w -g UnusedPin:PullNone -g StartUpClk:JtagClk top.ncd top.bit > bitgen.log 2>&1
ls -la top.bit
