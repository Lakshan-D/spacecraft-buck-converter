#!/usr/bin/env python3
"""Gain and phase margin of the digital PID + averaged buck plant (continuous approximation).

Controller:  C(jw) = Kp + (Ki/Ts)/(jw) + Kd*Ts*(jw)   [counts per code]
Delay:       exp(-j*w*1.5*Ts)   (1 period computation/apply delay + 0.5 period ZOH)
Plant:       codes per count = Vin * CODES_PER_V / PERIOD / (L*C*s^2 + (L/R + C*Rp)*s + 1)
"""
import numpy as np
L, C, RP, TS, PERIOD, CPV = 22e-6, 47e-6, 0.1, 5e-6, 500, 512.0
KP, KI, KD = 0.04, 0.004, 0.4


def loop(w, vin, r, kp=KP, ki=KI, kd=KD):
    s = 1j * w
    ctrl = kp + (ki / TS) / s + kd * TS * s
    plant = vin * CPV / PERIOD / (L * C * s ** 2 + (L / r + C * RP) * s + 1)
    return ctrl * plant * np.exp(-s * 1.5 * TS)


def margins(vin, r, **k):
    w = np.logspace(2.5, 5.6, 40000) * 2 * np.pi
    Lj = loop(w, vin, r, **k)
    mag = np.abs(Lj)
    ph = np.unwrap(np.angle(Lj)) * 180 / np.pi
    idx = np.where((mag[:-1] > 1) & (mag[1:] <= 1))[0]
    if len(idx) == 0:
        return None
    i = idx[-1]
    fc, pm = w[i] / 2 / np.pi, 180 + ph[i]
    j = np.where((ph[:-1] > -180) & (ph[1:] <= -180))[0]
    gm = -20 * np.log10(mag[j[0]]) if len(j) else float("inf")
    return fc, pm, gm


if __name__ == "__main__":
    print("Vin  R(ohm)  fc(kHz)  PM(deg)  GM(dB)")
    for vin in (22, 28, 36):
        for r in (1.667, 5.0, 16.67):
            m = margins(vin, r)
            print(f"{vin:3d}  {r:6.2f}  {m[0]/1e3:7.1f}  {m[1]:7.1f}  {m[2]:6.1f}")
