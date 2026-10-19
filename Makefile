# Usage:  make all     (everything, about 4 minutes, SPICE sweep is the slow part)
#         make sim golden plots   (Verilog only, about 1 minute with fault runs)
.PHONY: all spice sim golden fault ablate plots schematic clean

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

plots:
	python3 scripts/plot_results.py

schematic:
	python3 scripts/draw_schematic.py

clean:
	rm -f results/*.vvp results/loop_log.csv results/golden_log.csv results/fault_tmr*.csv results/fault_base_tmr*.csv results/ablation_*.csv
