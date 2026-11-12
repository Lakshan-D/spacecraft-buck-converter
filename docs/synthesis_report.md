# Synthesis report: taking the controller RTL through an FPGA flow

Until this step the Verilog had only been simulated. This note covers synthesis and
place and route with the open-source flow (yosys 0.70, nextpnr 0.11.1), what broke,
and how it was fixed without changing the control law.

Targets: Lattice ECP5 LFE5U-25F (CABGA256) as the main device, and the much smaller
iCE40 UP5K (SG48) as a stretch. Clock target 100 MHz, because the PWM counter needs
500 counts per 200 kHz switching period. Reproduce with `make synth`
(see `syn/run_synth.sh` for tool setup); the numbers below are in `syn/reports/summary.txt`.

## Results

| | Original (`pid_ctrl.v`, SEQ=0) | Multi-cycle (`pid_ctrl_seq.v`, SEQ=1) |
|---|---|---|
| Fmax on ECP5, 3 placement seeds | 4.66 to 4.70 MHz | **116.6 to 123.0 MHz** |
| Meets 100 MHz? | No (21x too slow) | Yes, 17 to 23 % margin |
| Critical path | 213.8 ns (83 ns logic, 130 ns routing) | 8.1 ns |
| Logic (TRELLIS_COMB) | 7412 (30 %) | 754 (3 %) |
| Flip-flops | 221 | 783 |
| DSP (MULT18X18D) | 15 of 28 | 4 of 28 |
| iCE40 UP5K | not attempted (does not fit) | fits: 1200 / 5280 LCs, 5 / 8 DSPs, but 35.5 MHz |

The multi-cycle controller is about 25x faster and about 10x smaller in logic. It
uses more flip-flops because the intermediate results are now registered.

## Problem 1: the whole controller was one combinational path

`pid_ctrl.v` computes the entire update in one clock: soft start compare, error,
three multiplies, the integrator add and clamp, the PID sum, and a 48-bit divide for
the Vin feedforward, all between one register and the next. In simulation that is
free. In hardware it is a 214 ns path, so the design runs at 4.7 MHz.

The controller only needs one new duty per switching period (500 clocks), so there
is plenty of time. `rtl/pid_ctrl_seq.v` does the same maths over 15 clocks, with at
most one wide add, compare or multiply between registers:

| Step | Work |
|---|---|
| 0 | tick: latch Vout ADC, Vin ADC and the voted state |
| 1 | soft start reference |
| 2 | error; feedforward numerator and denominator |
| 3 | e - e_prev; KI*e and KP*e on DSP blocks; divide overflow check |
| 4 | KD*(e - e_prev); integrator add |
| 5 | integrator clamp; KP and KD terms added |
| 6 | PID sum, arithmetic shift |
| 4 to 12 | feedforward divide, one quotient bit per clock |
| 13 | PID + feedforward |
| 14 | clamp to [0, DMAX], write the state |

Other changes that made it fit and close timing:

* **Divider.** The 48-bit combinational `/` became a 9-step restoring divider. Only 9
  quotient bits are needed, because the feedforward is clamped to DMAX = 400 < 512;
  a single overflow check (`num >= 512 * den`) covers everything above that.
* **Narrow datapaths.** e lies in [-4095, 4111] and e - e_prev in [-36863, 36879], so
  they are stored in 16 and 18 bits. That lets each multiply map onto DSP blocks
  instead of a 48 x 48 multiplier (15 DSPs down to 4). The feedforward numerator
  and denominator fit in 32 bits. All of these are exact, not approximations.

**Cost:** the new duty is applied 14 clocks (140 ns) into each switching period
instead of at its start, about 3 % of the period. Closed-loop results are within a
few millivolts (below).

## Problem 2: synthesis silently removed the TMR

The first synthesis runs reported only 80 flip-flops for the original design. TMR needs
3 x 70 = 210 for the state alone. The three state copies always load the same value
from the same logic, so the optimiser treated them as duplicates and merged them into
one. The voter then simplified to a wire. The bitstream would have had **no radiation
protection at all**, while every simulation said it worked.

Putting `(* keep *)` on the registers did not stop it. The fix is `rtl/tmr_copy.v`:
each copy is its own module instance marked `keep_hierarchy`, so the optimiser cannot
merge across them. This is the same job DONT_TOUCH or syn_preserve does in vendor tools.
After the fix the original design has 221 flip-flops (210 state + 10 PWM counter + 1),
and the copies and voter survive in the netlist of both architectures.

Lesson: TMR has to be checked in the synthesised netlist, not just in RTL simulation.

## Verification: is the multi-cycle version really the same controller?

`tb/tb_equiv.v` runs both controllers side by side. Each check loads the same state
into both (fully random 70-bit states, so corrupted states after an upset are covered),
applies the same random ADC codes and one tick, then compares the state each one writes,
bit for bit.

* 20 000 updates for each of 6 variants (TMR on/off, feedforward on/off, soft start
  on/off): **120 000 / 120 000 identical**.
* Directed corner cases: integrator landing exactly on or next to +/- IMAX, soft start
  reference landing on VREF, feedforward divides with and without a remainder, Vin = 0,
  and one TMR copy upset or holding garbage.
* Mutation check, to make sure the testbench can fail: 7 small bugs were planted in
  `pid_ctrl_seq.v` one at a time. Every one that changes behaviour was caught
  (17 to 2191 mismatches out of 20 000 each). The two that passed are provably equivalent rewrites:
  `ref_inc >= VREF` vs `ref_inc > VREF` give VREF either way, and bits 46 and 47 of
  `u_raw` are always equal sign bits.

Then the closed loop and fault injection were re-run with SEQ = 1 (`make sim_seq fault_seq`):

| Check | SEQ=0 (original) | SEQ=1 (multi-cycle) |
|---|---|---|
| RTL vs Python golden model | 1299 / 1299 | 1299 / 1299 |
| Start-up overshoot | 73.3 mV | 73.2 mV |
| Load step 3 to 0.3 A | 207.4 mV | 208.1 mV |
| Load step 0.3 to 3 A | 202.9 mV | 202.6 mV |
| Line step 28 to 22 V | 30.6 mV | 30.1 mV |
| Line step 22 to 36 V | 59.9 mV | 58.5 mV |
| Line step 36 to 28 V | 23.2 mV | 23.7 mV |
| Upsets > 100 mV, no TMR | 69 / 200 | 72 / 200 |
| Upsets > 100 mV, with TMR | **0 / 200** | **0 / 200** |

The no-TMR count differs slightly because the 14-clock delay shifts when each upset
lands relative to the controller update. TMR still stops all 200.

With SEQ = 0 every committed result (`loop_log.csv`, `golden_log.csv`,
`fault_tmr0.csv`, `fault_tmr1.csv`) is reproduced byte for byte after these changes.

## iCE40 UP5K

The multi-cycle design fits the UP5K comfortably (22 % of logic, 5 of 8 DSPs), but the
iCE40 fabric is slow and closes at 35.5 MHz. Running there would need a lower clock and
a matching PERIOD (for example 35 MHz and PERIOD = 175 for 200 kHz, which coarsens the
duty resolution from 500 to 175 steps and means retuning). Not done.

## Still not done

* No hardware: no bitstream has been loaded onto a board.
* Timing is from nextpnr's built-in model for the ECP5 speed grade it targets by
  default; I/O timing and the ADC interface are not constrained.
* TMR covers the controller state only. The PWM counter, the pipeline registers inside
  `pid_ctrl_seq.v` and the voter itself are not triplicated. An upset in a pipeline
  register during the 14 busy clocks of an update can write a wrong value into all
  three copies at once, which TMR cannot then correct. The exposure is small (14 of
  every 500 clocks, in registers that are idle the rest of the time) but it is not zero.
* Not checked with a vendor tool (Lattice Radiant / Diamond, Vivado). Their optimisers
  may treat the TMR copies differently again, so the netlist check would need repeating.
