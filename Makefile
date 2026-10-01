# Usage:  make all     (everything, about 4 minutes, SPICE sweep is the slow part)
#         make sim golden plots   (Verilog only, about 1 minute with fault runs)
.PHONY: all spice sim golden fault plots schematic clean

all: spice sim golden fault plots schematic

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

plots:
	python3 scripts/plot_results.py

schematic:
	python3 scripts/draw_schematic.py

clean:
	rm -f results/*.vvp results/loop_log.csv results/golden_log.csv results/fault_tmr*.csv
