#!/usr/bin/env python3
"""Float-domain PID tuning on an averaged buck model (continuous plant, ZOH, 1-period delay).

Plant: Vo/d = Vin / (L*C*s^2 + (L/R + C*Rp)*s + 1), d = duty fraction (0..1).
Controller works in ADC codes / duty counts, so gains are in counts per code.
Prints a table of candidate gains with stability metrics across Vin and load corners.
"""
import numpy as np
from scipy.linalg import expm

L, C, RP = 22e-6, 47e-6, 0.1
TS = 5e-6            # control period = PWM period
PERIOD = 500         # counts per PWM period
CODES_PER_V = 512.0  # 12-bit ADC, 8 V full scale
VREF_CODE = 2560     # 5.000 V


def plant_disc(vin, rload):
    A = np.array([[-RP / L, -1 / L], [1 / C, -1 / (rload * C)]])  # states: iL, vc
    B = np.array([[vin / L], [0.0]])
    n = 2
    M = np.zeros((n + 1, n + 1))
    M[:n, :n] = A * TS
    M[:n, n:] = B * TS
    E = expm(M)
    return E[:n, :n], E[:n, n:]


def simulate(kp, ki, kd, vin, rload, steps=400, vstart=0.0, fl=None):
    Ad, Bd = plant_disc(vin, rload)
    x = np.array([[0.0], [vstart]])
    integ, e_prev = 0.0, 0.0
    duty = 0.0
    out = []
    for k in range(steps):
        adc = x[1, 0] * CODES_PER_V
        e = VREF_CODE - adc
        integ = min(max(integ + ki * e, 0.0), 0.8 * PERIOD)
        u = kp * e + integ + kd * (e - e_prev)
        e_prev = e
        d_next = min(max(u, 0.0), 0.8 * PERIOD)
        # duty computed now applies during the next period
        x = Ad @ x + Bd * (duty / PERIOD)
        duty = d_next
        out.append(x[1, 0])
    return np.array(out)


def metrics(kp, ki, kd):
    worst_os, worst_settle, stable = 0.0, 0, True
    for vin in (22, 28, 36):
        for rload in (1.667, 5.0, 16.67):
            v = simulate(kp, ki, kd, vin, rload, vstart=4.5)
            if not np.all(np.isfinite(v)) or np.abs(v).max() > 20:
                return None
            tail = v[-40:]
            if np.abs(tail - 5.0).max() > 0.02:
                return None
            os_ = max(0.0, v.max() - 5.0)
            band = np.abs(v - 5.0) > 0.025
            settle = (np.where(band)[0].max() + 1) if band.any() else 0
            worst_os = max(worst_os, os_)
            worst_settle = max(worst_settle, settle)
    return worst_os, worst_settle * TS * 1e6


if __name__ == "__main__":
    best = []
    for kp in (0.01, 0.02, 0.03, 0.05, 0.08):
        for ki in (0.001, 0.002, 0.004, 0.008, 0.016):
            for kd in (0.0, 0.05, 0.1, 0.2, 0.3, 0.5):
                m = metrics(kp, ki, kd)
                if m:
                    best.append((m[1], m[0], kp, ki, kd))
    best.sort()
    print("settle_us  overshoot_V  kp     ki      kd")
    for s, o, kp, ki, kd in best[:15]:
        print(f"{s:8.1f}  {o:10.3f}  {kp:5.3f}  {ki:6.4f}  {kd:5.2f}")
