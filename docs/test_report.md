# Test report

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
