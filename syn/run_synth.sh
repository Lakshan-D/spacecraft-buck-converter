#!/usr/bin/env bash
# Synthesis + place and route with the open-source flow (yosys, nextpnr).
#   ECP5 LFE5U-25F (CABGA256): both controller architectures, 3 placement seeds each
#   iCE40 UP5K (SG48): the multi-cycle controller
# Tools: yosys and nextpnr-ecp5 / nextpnr-ice40 on PATH, or the pip packages
#   pip install yowasp-yosys yowasp-nextpnr-ecp5 yowasp-nextpnr-ice40
# and run with YOSYS=yowasp-yosys NEXTPNR_ECP5=yowasp-nextpnr-ecp5 NEXTPNR_ICE40=yowasp-nextpnr-ice40.
# Build files go to syn/build/ (not committed); a summary goes to syn/reports/summary.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
YOSYS=${YOSYS:-yosys}
NP_ECP5=${NEXTPNR_ECP5:-nextpnr-ecp5}
NP_ICE40=${NEXTPNR_ICE40:-nextpnr-ice40}
B=syn/build; R=syn/reports
mkdir -p $B $R
SRC="rtl/pwm_gen.v rtl/tmr_voter.v rtl/tmr_copy.v rtl/pid_ctrl.v rtl/pid_ctrl_seq.v rtl/buck_ctrl_top.v"
OUT=$R/summary.txt
{
  echo "Synthesis summary ($(date -u +%Y-%m-%d), $($YOSYS -V | cut -d' ' -f1-2), $($NP_ECP5 --version 2>&1 | grep -o 'nextpnr-[0-9.]*' | head -1))"
  echo "Target clock 100 MHz (PERIOD = 500 counts for 200 kHz PWM)."
} > $OUT

for seq in 0 1; do
  $YOSYS -q -p "read_verilog -sv $SRC; chparam -set SEQ $seq buck_ctrl_top; \
                synth_ecp5 -top buck_ctrl_top -json $B/ecp5_seq$seq.json; tee -q -o $B/ecp5_seq${seq}_stat.txt stat"
  echo "" >> $OUT; echo "== ECP5 LFE5U-25F, SEQ=$seq" >> $OUT
  for seed in 1 2 3; do
    $NP_ECP5 --25k --package CABGA256 --json $B/ecp5_seq$seq.json --freq 100 \
             --timing-allow-fail --seed $seed > $B/ecp5_seq${seq}_s$seed.log 2>&1
    echo "seed $seed: $(grep 'Max frequency' $B/ecp5_seq${seq}_s$seed.log | tail -1 | sed 's/.*: //')" >> $OUT
  done
  grep -E "TRELLIS_COMB:|TRELLIS_FF:|MULT18X18D:" $B/ecp5_seq${seq}_s1.log | sed 's/Info: *//' >> $OUT
  grep -E "ns logic, .* ns routing" $B/ecp5_seq${seq}_s1.log | head -1 | sed 's/Info: /critical path: /' >> $OUT
done

$YOSYS -q -p "read_verilog -sv $SRC; chparam -set SEQ 1 buck_ctrl_top; \
              synth_ice40 -top buck_ctrl_top -dsp -json $B/ice40_seq1.json"
$NP_ICE40 --up5k --package sg48 --json $B/ice40_seq1.json --freq 100 --timing-allow-fail --seed 1 > $B/ice40_seq1.log 2>&1
{
  echo ""; echo "== iCE40 UP5K, SEQ=1"
  echo "seed 1: $(grep "Max frequency for clock *'clk" $B/ice40_seq1.log | tail -1 | sed 's/.*: //')"
  grep -A12 "Device utilisation" $B/ice40_seq1.log | grep -E "ICESTORM_LC:|ICESTORM_DSP:" | sed 's/Info: *//'
} >> $OUT
cat $OUT
