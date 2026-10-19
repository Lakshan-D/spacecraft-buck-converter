# Test report

This report has three parts. Iteration 1 (47 uF output capacitor) is the first run. Iteration 2 (150 uF, retuned gains) follows, with a before and after comparison. Iteration 3 (Vin feedforward and soft start) is at the end. The Summary table below and the sections up to Reproducing describe iteration 1; the requirement status after iteration 3 is in the last section.

All numbers come from the scripts in this repo (`make all`) and the tables in `results/`. Requirements are the self-set ones in `docs/design_note.md`.

## Summary

| ID | Requirement | Result | Status |
|---|---|---|---|
| R1 | Steady-state Vout 5.00 V +/- 1 % | 5.0056 V (Verilog closed loop, 28 V, 3 A) | Pass |
| R2 | Output ripple <= 50 mV pk-pk | 14 mV nominal, 21 mV worst of 18 SPICE corners | Pass |
| R3 | Efficiency >= 90 % at 3 A, 22 to 36 V | 91.1 to 92.4 % (conduction losses only) | Pass, with the caveat that switching loss is not modelled |
| R4 | Recovery to +/-50 mV in < 500 us after load or line step | 181 to 241 us | Pass |
| R5 | Step excursion <= 250 mV (5 %) | 429 to 1011 mV | **Fail** |
| R6 | Phase margin >= 45 deg, gain margin >= 6 dB | 45.3 deg, 8.8 dB worst case | Pass (little spare margin) |
| R7 | RTL equals Python golden model | 1299 / 1299 ticks identical | Pass |
| R8 | Single-bit upset must not move Vout by more than 100 mV | No TMR: 82 / 200 violations. TMR: 0 / 200 | Pass with TMR |

## Power stage (SPICE)

Full corner table: `results/spice_summary.md`, raw data `results/spice_corners.csv`.
Plots: `results/spice_steady_state.png`, `results/spice_load_step_open_loop.png`, `results/spice_efficiency.png`.

Open-loop line regulation at fixed duty is poor (3.87 V at 22 V in, 6.51 V at 36 V in), and the open-loop load step rings strongly. This is the reason for the controller.

## Closed loop (Verilog + behavioural plant)

Table: `results/loop_summary.md`. Plots: `results/loop_response.png`, `results/loop_load_step_zoom.png`.

| Event | Peak deviation (mV) | Settling to +/-50 mV (us) |
|---|---|---|
| Start-up (28 V, 3 A) | 16 over | 206 |
| Load 3 A to 0.3 A | 672 over | 181 |
| Load 0.3 A to 3 A | 606 under | 213 |
| Bus 28 V to 22 V | 500 under | 241 |
| Bus 22 V to 36 V | 1011 over | 228 |
| Bus 36 V to 28 V | 429 under | 211 |

Why R5 fails: a 2.7 A load step into 47 uF at a 10 kHz crossover gives roughly 0.9 V of droop from simple charge arguments (dI / (2 pi fc C)), and the sim agrees. A 14 V instantaneous bus step with no feedforward is also severe. Real bus transients are usually specified differently and slower, so the line-step numbers are conservative, but the load-step miss is genuine for this capacitor and bandwidth.

## Verification of the RTL

`scripts/golden_model.py` re-implements the controller in Python integers and compares it with the RTL output for every control tick of the closed-loop run. All 1299 ticks match, which checks that the Verilog arithmetic (signed maths, shifts, clamps) does what the specification says.

## Fault injection (SEU)

Method: after the loop settles at 28 V and 3 A, flip one random bit of one random state copy at a random phase of the switching period, observe Vout for 300 us, repeat 200 times (seed fixed, same bit and time sequence for both runs). Table: `results/fault_summary.md`. Plot: `results/fault_injection.png`.

| Metric | No TMR | TMR |
|---|---|---|
| Upsets with error > 100 mV | 82 / 200 | 0 / 200 |
| Upsets with error > 250 mV | 75 / 200 | 0 / 200 |
| Not recovered within 250 us | 28 / 200 | 0 / 200 |
| Worst peak error | 13.4 V | 14 mV (normal ripple) |

Without TMR, flips in the previous-error register and in the upper integrator bits were the worst. Low integrator bits and low duty bits were harmless because the loop corrects them. The 13 V figure appears because the model has no output over-voltage protection.

Not covered: upsets in the PWM counter, ADC, clock or configuration memory, multiple-bit upsets, and any physical radiation effects (total dose, latch-up).

## Reproducing

    make all

SPICE takes about 3 minutes, the Verilog runs about 1 minute. Tested with Icarus Verilog 12, ngspice 42, Python 3.13.


## Iteration 2: larger output capacitor and retuned PID

Why: iteration 1 failed R5 (step excursion 429 to 1011 mV against a 250 mV target). The hand calculation dV about dI / (2 pi fc C) pointed at the 47 uF capacitor, so Cout was raised to 150 uF (predicted droop about 0.29 V at the same crossover).

What changed: Cout 47 uF to 150 uF in `tb/buck_plant.v`, both SPICE netlists, `scripts/tune_pid.py` and `scripts/loop_margins.py`. The larger capacitor lowers the LC resonance from 4.95 kHz to 2.77 kHz, so the PID was retuned (grid search with phase margin at least 45 deg and gain margin at least 6 dB at all nine Vin and load corners). New gains: Kp 0.10, Ki 0.008, Kd 1.60 (Q16: 6554, 524, 104858), previously 0.04, 0.004, 0.40. The golden model and RTL were updated together.

| Check | Iteration 1 (47 uF) | Iteration 2 (150 uF) |
|---|---|---|
| Steady-state Vout | 5.0056 V | 5.0011 V |
| Ripple, worst of 18 SPICE corners | 21 mV | 18 mV |
| Load step 3 A to 0.3 A | 672 mV | 209 mV |
| Load step 0.3 A to 3 A | 606 mV | 203 mV |
| Bus 28 V to 22 V | 500 mV | 232 mV |
| Bus 36 V to 28 V | 429 mV | 193 mV |
| Bus 22 V to 36 V | 1011 mV | 438 mV |
| Recovery to +/-50 mV, load and line steps | 181 to 241 us | 215 to 391 us |
| Phase margin / gain margin (worst case) | 45.3 deg / 8.8 dB | 46.0 deg / 7.2 dB |
| Start-up overshoot / peak inductor current | 16 mV / 5.6 A | 1079 mV / 10.3 A |
| RTL vs golden model | 1299 / 1299 | 1299 / 1299 |
| Bit flips causing > 100 mV, no TMR | 82 / 200 (worst 13.4 V) | 70 / 200 (worst 2.8 V) |
| Bit flips causing > 100 mV, TMR | 0 / 200 | 0 / 200 |

Result: R5 now passes for the load steps (203 to 209 mV) and for two of the three line steps. The 14 V instantaneous line step from 22 V to 36 V is still 438 mV, which would need Vin feedforward. Recovery is slower (up to 391 us, still inside the 500 us limit) and the stability margins are slightly tighter at the highest input voltage.

New problem found: with 150 uF and no soft start, start-up now overshoots by 1.08 V and draws a 10.3 A inrush peak. A real design needs soft start. The no-TMR fault run is milder (worst 2.8 V) largely because the bigger capacitor slows how fast a wrong duty moves the output, but 70 of 200 flips still exceed 100 mV, and TMR still stops all of them.


## Iteration 3: Vin feedforward and soft start

Why: iteration 2 left two known problems. The 22 to 36 V line step gave 438 mV against the 250 mV target, and start-up overshot by 1.08 V with a 10.3 A inrush peak.

What changed, all in `rtl/pid_ctrl.v` and its testbenches, with `scripts/golden_model.py` updated to match:

* Vin feedforward. A buck has Vout = D * Vin, so the controller now adds `ff = ref * PERIOD * VIN_CPV / (ADC_CPV * vin)` duty counts to the PID output, using a Vin ADC code (100 codes per volt, so 28 V is 2800). The integrator now swings both ways (clamp of plus or minus the duty limit instead of 0 to the duty limit) because it only holds the leftover duty after the feedforward.
* Soft start. The reference ramps from 0 to 5 V at 16 ADC codes (31 mV) per switching period, 0.8 ms in total. The ramped reference feeds both the error and the feedforward.
* The soft start reference is a 12-bit register inside the TMR state, so the controller state is now 70 bits instead of 58.
* The plant model gets a Vin ADC output (ideal, 10 mV per code), and both testbenches connect it.

Feedforward sits outside the feedback loop and soft start only changes the reference, so the loop gain, the PID gains and the margins from `scripts/loop_margins.py` (46 deg, 7.2 dB worst case) are unchanged. The SPICE power stage is unchanged and was not re-run.

Check that the change is clean: with `FF_EN=0` and `SS_STEP=0` the RTL reproduces the iteration 2 waveform exactly (`results/loop_log.csv` identical in all six columns), and the golden model matches the new RTL on 1299 / 1299 ticks with both features on and off.

### Before and after

| Check | Iteration 2 | Iteration 3 |
|---|---|---|
| Steady-state Vout | 5.0011 V | 5.0017 V |
| Ripple (Verilog model) | 7.4 mV | 7.1 mV |
| Load step 3 A to 0.3 A | 209 mV | 207 mV |
| Load step 0.3 A to 3 A | 203 mV | 203 mV |
| Bus 28 V to 22 V | 232 mV | 31 mV |
| Bus 22 V to 36 V | 438 mV | 60 mV |
| Bus 36 V to 28 V | 193 mV | 23 mV |
| Recovery to +/-50 mV, load steps | 221 to 233 us | 226 to 229 us |
| Recovery to +/-50 mV, line steps | 215 to 391 us | 0 to 49 us |
| Start-up overshoot | 1079 mV | 73 mV |
| Start-up peak inductor current | 10.3 A | 4.4 A |
| Time to reach +/-50 mV at start-up | 552 us | 868 us (the ramp itself is 800 us) |
| RTL vs golden model | 1299 / 1299 | 1299 / 1299 |

Load steps do not change because feedforward only reacts to Vin. Start-up is slower on purpose.

### Each fix on its own (`results/ablation_summary.md`, `results/ablation.png`)

Peak deviation in mV / settling in us / peak inductor current in A.

| Event | Neither | Feedforward only | Soft start only | Both |
|---|---|---|---|---|
| Start-up | 1079 / 552 / 10.3 | 1577 / 551 / 12.8 | 10 / 901 / 4.3 | 73 / 868 / 4.4 |
| Bus 28 V to 22 V | 232 / 226 / 3.5 | 30 / 0 / 3.3 | 234 / 226 / 3.5 | 31 / 0 / 3.3 |
| Bus 22 V to 36 V | 438 / 391 / 4.9 | 60 / 49 / 4.0 | 438 / 391 / 4.9 | 60 / 49 / 4.0 |
| Bus 36 V to 28 V | 193 / 215 / 3.6 | 24 / 0 / 3.5 | 194 / 216 / 3.6 | 23 / 0 / 3.5 |

Feedforward alone fixes the line steps and makes start-up worse (it adds duty for the full 5 V target immediately, so the inrush reaches 12.8 A). Soft start alone fixes start-up and leaves the line steps as they were. The two fixes are independent, and you need both.

With both on, start-up overshoots by 73 mV (1.5 %) at the end of the ramp. The feedforward makes the output follow the ramp closely, so the PID sees a sudden change in slope at 0.8 ms and overshoots a little. Soft start alone has only 10 mV overshoot because the output lags the ramp. 73 mV is inside the 250 mV target, so it was left alone.

### Fault injection

The injected state grew from 58 to 70 bits, so the random bit and time draws are different from iteration 2's published run (which had 70 / 200 above 100 mV). For a fair comparison the iteration 2 controller was re-run with the same 70-bit draws (its 12 extra bits are unused, so some flips there are harmless).

| Controller | Mode | Upsets > 100 mV | Upsets > 250 mV | Not recovered in 250 us | Worst peak (mV) |
|---|---|---|---|---|---|
| Iteration 2 | no TMR | 57 / 200 | 43 / 200 | 35 / 200 | 2807 |
| Iteration 2 | TMR | 0 / 200 | 0 / 200 | 0 / 200 | 7 |
| Feedforward + soft start | no TMR | 69 / 200 | 54 / 200 | 44 / 200 | 5692 |
| Feedforward + soft start | TMR | 0 / 200 | 0 / 200 | 0 / 200 | 6 |

TMR still stops every upset in the injected set.

Without TMR the two controllers look about the same. The raw counts are 57 versus 69 above 100 mV, but the injections run back to back, and without TMR some upsets are still recovering when the next one lands, which inflates that next peak (35 and 44 of 200 had not recovered at the end of their window). Dropping upsets that started while the previous one was still recovering gives 33 / 165 for iteration 2 and 34 / 156 for iteration 3. That back-to-back protocol was already in iteration 2's published numbers and has not been changed. A cleaner version would reset or wait for recovery between injections. The difference between the two controllers is inside the noise for 200 samples.

There is one real, specific change: the soft start reference register. At 5 V it holds 2560, so clearing bit 11 (value 2048) or bit 9 (value 512) drops the reference and the controller re-ramps up to 5 V. Of the 25 flips that hit that register on clean starts, the 5 that caused more than 100 mV were all bit 11 (four times, 4.5 V dip) and bit 9 (once, 507 mV). Setting any other bit just saturates back to VREF on the next tick. TMR out-votes all of these.

### What this does not show

* The Vin sense is ideal. A real one has noise, filtering delay and gain error. The feedforward would be a little slower and a little less exact, and the integrator would trim the rest.
* The bus steps are instantaneous 6 to 14 V steps, which is harsher than most real bus transient specs, but a real bus also has an input filter and source impedance that this model does not have.
* The feedforward divide is a 48-bit combinational `/`. It simulates, but the RTL has not been synthesised or timed and a divider that wide would not close timing at 100 MHz on a small FPGA. A real version needs a multi-cycle divider or a reciprocal table.
* The soft start rate (0.8 ms) was picked by reasoning about inrush (C dV/dt = 150 uF at 6.25 V/ms is about 0.9 A on top of the load) and was not optimised. Only one value was run.
* Still no output over-voltage protection, no discontinuous conduction mode, no switching losses, and everything is simulation only.

### Requirement status after iteration 3

| ID | Requirement | Result | Status |
|---|---|---|---|
| R1 | Steady-state Vout 5.00 V +/- 1 % | 5.0017 V | Pass |
| R2 | Output ripple <= 50 mV pk-pk | 18 mV worst of 18 SPICE corners (unchanged) | Pass |
| R3 | Efficiency >= 90 % at 3 A | 91.1 to 92.4 % (unchanged, conduction losses only) | Pass, same caveat |
| R4 | Recovery to +/-50 mV in < 500 us after load or line step | 0 to 229 us | Pass |
| R5 | Step excursion <= 250 mV (5 %) | Load 203 to 207 mV, line 23 to 60 mV | Pass |
| R6 | Phase margin >= 45 deg, gain margin >= 6 dB | 46 deg / 7.2 dB (unchanged) | Pass |
| R7 | RTL equals Python golden model | 1299 / 1299 | Pass |
| R8 | Single-bit upset must not move Vout by more than 100 mV | No TMR: 69 / 200 violations. TMR: 0 / 200 | Pass with TMR |
| R9 | Start-up overshoot <= 250 mV and peak inductor current <= 5 A | 73 mV, 4.4 A | Pass |

R9 was added in iteration 3 after the start-up problem was found, so it is a check on the fix, not an independent requirement.

Reproducing the iteration 3 numbers: `make sim golden fault plots ablate`.
