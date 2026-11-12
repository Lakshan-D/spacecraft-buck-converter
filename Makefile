# Usage:  make all     (everything, about 4 minutes, SPICE sweep is the slow part)
#         make sim golden plots   (Verilog only, about 1 minute with fault runs)
#         make equiv sim_seq fault_seq   (multi-cycle controller checks, about 2 minutes)
#         make synth   (yosys + nextpnr, about 15 minutes; see syn/run_synth.sh for tools)
.PHONY: all spice sim golden fault ablate plots schematic clean equiv sim_seq fault_seq synth

all: spice sim golden fault ablate plots schematic

spice:
	python3 scripts/run_spice.py

sim:
	mkdir -p results
	iverilog -g2012 -o results/loop.vvp rtl/*.v tb/buck_plant.v tb/tb_buck_loop.v
	vvp results/loop.vvp

golden: sim
	python3 scripts/golden_model.py

fault:
	mkdir -p results
	iverilog -g2012 -Ptb_fault_inject.TMR=0 -o results/fault0.vvp rtl/*.v tb/buck_plant.v tb/tb_fault_inject.v
	iverilog -g2012 -Ptb_fault_inject.TMR=1 -o results/fault1.vvp rtl/*.v tb/buck_plant.v tb/tb_fault_inject.v
	vvp results/fault0.vvp & vvp results/fault1.vvp & wait

# Four controller variants (neither, feedforward only, soft start only, both) plus the
# iteration 2 controller under the same fault sequence, for the before/after tables.
ablate:
	mkdir -p results
	for c in "base 0 0" "ff 1 0" "ss 0 16" "both 1 16"; do set -- $$c; \
	  iverilog -g2012 -Ptb_buck_loop.FF_EN=$$2 -Ptb_buck_loop.SS_STEP=$$3 -o results/abl_$$1.vvp rtl/*.v tb/buck_plant.v tb/tb_buck_loop.v && \
	  vvp results/abl_$$1.vvp +tag=$$1 | grep -v finish; done
	for t in 0 1; do \
	  iverilog -g2012 -Ptb_fault_inject.TMR=$$t -Ptb_fault_inject.FF_EN=0 -Ptb_fault_inject.SS_STEP=0 -o results/faultb$$t.vvp rtl/*.v tb/buck_plant.v tb/tb_fault_inject.v; done
	vvp results/faultb0.vvp +tag=base & vvp results/faultb1.vvp +tag=base & wait
	cd scripts && python3 ablation.py

# pid_ctrl_seq.v (multi-cycle, for synthesis) against pid_ctrl.v (single-cycle reference):
# 20000 random and corner-case updates per controller variant, must be bit-identical.
equiv:
	mkdir -p results
	for c in "1 1 16" "0 1 16" "1 0 0" "0 0 0" "1 1 0" "1 0 16"; do set -- $$c; \
	  iverilog -g2012 -Ptb_equiv.TMR=$$1 -Ptb_equiv.FF_EN=$$2 -Ptb_equiv.SS_STEP=$$3 -o results/equiv.vvp \
	    rtl/pid_ctrl.v rtl/pid_ctrl_seq.v rtl/tmr_voter.v rtl/tmr_copy.v tb/tb_equiv.v && \
	  vvp -n results/equiv.vvp | grep tb_equiv; done

# Closed loop and fault injection with the multi-cycle controller (SEQ=1)
sim_seq:
	mkdir -p results
	iverilog -g2012 -Ptb_buck_loop.SEQ=1 -o results/loop_seq.vvp rtl/*.v tb/buck_plant.v tb/tb_buck_loop.v
	vvp -n results/loop_seq.vvp +tag=seq +gold=results/golden_seq.csv | grep -v finish
	python3 scripts/golden_model.py --log results/golden_seq.csv

fault_seq:
	mkdir -p results
	for t in 0 1; do iverilog -g2012 -DSEQ_CTRL -Ptb_fault_inject.SEQ=1 -Ptb_fault_inject.TMR=$$t \
	  -o results/fault_seq$$t.vvp rtl/*.v tb/buck_plant.v tb/tb_fault_inject.v; done
	vvp -n results/fault_seq0.vvp +tag=seq & vvp -n results/fault_seq1.vvp +tag=seq & wait

synth:
	./syn/run_synth.sh

plots:
	python3 scripts/plot_results.py

schematic:
	python3 scripts/draw_schematic.py

clean:
	rm -rf syn/build
	rm -f results/*.vvp results/loop_log.csv results/golden_log.csv results/fault_tmr*.csv results/fault_base_tmr*.csv results/ablation_*.csv results/golden_seq.csv results/fault_seq_tmr*.csv
