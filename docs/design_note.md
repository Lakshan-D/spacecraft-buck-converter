# Design note: 28 V bus to 5 V / 3 A buck converter

Author: Lakshan Divakar. Status: simulation study, not built.

## 1. Requirements and assumptions

| Item | Value | Source |
|---|---|---|
| Input bus | 22 to 36 V, nominal 28 V | Assumption for this study (typical 28 V spacecraft bus range) |
| Output | 5.0 V, 0.3 to 3 A | Assumption |
| Switching frequency | 200 kHz | Chosen: small magnetics, 100 MHz clock gives 500 counts per period |
| Output ripple | <= 50 mV pk-pk | Assumption |
| Regulation | +/-1 % steady state | Assumption |
| Load / line step recovery | back within +/-50 mV in < 500 us | Assumption |
| Load / line step excursion | <= 5 % (250 mV) | Assumption (this one is NOT met, see test report) |
| Loop stability | phase margin >= 45 deg, gain margin >= 6 dB | Common design rule |
| Parts stress | <= 80 % of rating (voltage), derating margin on current | Rule of thumb. A real project would use its own derating standard (for example ECSS-Q-ST-30-11 or customer requirements) |

## 2. Power stage sizing

Duty cycle: D = Vout / Vin = 5 / 28 = 0.18 (about 0.19 once drops are included).

Inductor, for 30 % peak-to-peak ripple current at 3 A (0.9 A) and 200 kHz:

    L = Vout (1 - D) / (fsw * dIL) = 5 * 0.82 / (200e3 * 0.9) = 22.8 uH  ->  22 uH

Output capacitor, for about 25 mV ripple from the capacitance alone:

    Cout = dIL / (8 * fsw * dV) = 0.9 / (8 * 200e3 * 0.025) = 22.5 uF  ->  47 uF (margin for tolerance and DC-bias loss)

Resonance of the output filter: f0 = 1 / (2 pi sqrt(L C)) = 4.95 kHz. This is the double pole the controller has to deal with.

Simulated ripple current is 1.0 A pk-pk (34 %) at the nominal point.

## 3. Component stress and derating (from the SPICE corner sweep)

Worst-case values come from the 18-corner sweep (Vin 22/28/36 V, Iout 0.3/3 A, cold/typical/hot parts) in `results/spice_summary.md`.

| Part | Worst-case stress | Example rating | Ratio |
|---|---|---|---|
| High-side switch | Vds 37.6 V (36 V plus ringing), Id peak 3.5 A | 60 V, 10 A | 63 % V, 35 % I |
| Freewheel diode | Vr 37.6 V, mean current about 2.6 A | 60 V, 5 A Schottky | 63 % V, 51 % I |
| Inductor | Ipeak 3.53 A, ripple 1.0 A | Isat >= 5 A | 71 % |
| Output capacitor | 5 V, ripple current about 0.3 A rms (dIL / sqrt 12) | 16 V ceramic or tantalum | 31 % V |
| Input capacitor | 36 V, ripple about 1.3 A rms (Iout * sqrt(D(1-D))) | 50 V X7R | 72 % V |

The ratings are examples chosen for the maths, not a bill of materials. No radiation-hardness screening of parts was done.

## 4. Losses

At the nominal point (28 V, 3 A) SPICE gives 91.8 % efficiency, about 1.3 W of loss on 15 W out. Roughly 1.2 W of that is the freewheel diode (about 0.5 V drop times 3 A times 0.81 off-time). The FET conduction loss is under 0.1 W. Switching and gate-drive losses are NOT modelled. Swapping the diode for a synchronous FET is the obvious next improvement.

## 5. Control design

The controller is a fixed-point PID acting on the sampled output voltage. Plant seen by the controller (averaged model):

    Vo / d = Vin / (L C s^2 + (L/R + C Rp) s + 1)

with Rp = 0.1 ohm for DCR and Rds(on). The controller adds a zero pair to cancel the 5 kHz double pole, an integrator for zero steady-state error, and the digital loop has about 1.5 periods of delay (1 period compute and apply, 0.5 period ZOH).

Gains (counts of duty per ADC code): Kp = 0.04, Ki = 0.004 per sample, Kd = 0.4. In Q16 these are 2621, 262 and 26214. They came from a grid search in `scripts/tune_pid.py`, accepting only gains that were stable and settled with no more than a few tens of mV overshoot at every Vin (22/28/36 V) and load (1.667/5/16.7 ohm) corner, then filtering for margins with `scripts/loop_margins.py`.

Loop margins (continuous approximation of the sampled loop):

| Vin (V) | Load (ohm) | Crossover (kHz) | Phase margin (deg) | Gain margin (dB) |
|---|---|---|---|---|
| 22 | 1.67 | 8.7 | 68.6 | 13.4 |
| 22 | 5 | 9.1 | 56.0 | 13.2 |
| 22 | 16.7 | 9.2 | 51.8 | 13.1 |
| 28 | 1.67 | 10.3 | 62.4 | 11.3 |
| 28 | 5 | 10.6 | 52.6 | 11.1 |
| 28 | 16.7 | 10.7 | 49.3 | 11.0 |
| 36 | 1.67 | 12.6 | 55.4 | 9.2 |
| 36 | 5 | 12.8 | 47.8 | 8.9 |
| 36 | 16.7 | 12.9 | 45.3 | 8.8 |

Worst case is 45.3 deg and 8.8 dB at high line and light load. That meets the rule above but with little spare phase margin. A time-domain check with gains scaled from 0.5x to 1.5x stayed stable.

## 6. Digital implementation choices

* 12-bit ADC, 8 V full scale, so 5.000 V is code 2560.
* 200 kHz PWM from a 100 MHz clock, 500 counts per period, so duty resolution is 0.2 %.
* Duty limited to 80 % (400 counts). Integrator clamped between 0 and the duty limit, which is the anti-windup.
* All arithmetic in 48-bit signed inside the controller so that a corrupted state value cannot overflow.
* The PID math is combinational in one cycle. That is fine for simulation. On a real FPGA at 100 MHz the multipliers would use DSP blocks and may need a pipelined or multi-cycle version; this has not been checked.

## 7. Radiation tolerance approach (single-event upsets)

Charged particles can flip bits in registers (single-event upsets, SEU). In a closed-loop controller a flipped integrator or duty bit can drive the output far off target before the loop recovers. The mitigation implemented here is triple modular redundancy:

* The controller state is stored three times.
* A bitwise majority voter produces the value used by the control law and the PWM.
* The voted next state is written to all three copies every switching period (scrubbing), so a single upset cannot accumulate into a second one.
* A mismatch flag reports that an upset was corrected.

Results are in `results/fault_summary.md`. Limits of this approach are listed in the README: it does not protect the PWM counter, ADC path or clock, and two upsets in different copies within one period would defeat the voter.

## 8. Open issues

* Transient excursions are 9 to 20 % against a 5 % target. Contributing factors: only 47 uF of output capacitance, about 10 kHz crossover, and no input voltage feedforward. Options: more Cout, higher bandwidth, Vin feedforward, or a load-current feedforward.
* Efficiency number excludes switching losses.
* Discontinuous conduction at light load is not covered by the control model.
* No soft start: start-up inrush reaches 5.6 A.
