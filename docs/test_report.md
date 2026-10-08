# Test report

This report has two parts. Iteration 1 (47 uF output capacitor) is the first run. Iteration 2 (150 uF, retuned gains) is at the end, with a before and after comparison.

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
