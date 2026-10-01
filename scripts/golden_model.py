#!/usr/bin/env python3
"""Bit-exact Python golden model of rtl/pid_ctrl.v.

Reads results/golden_log.csv (ADC code at each control tick, duty the RTL produced),
re-computes the duty with integer maths and checks every single sample matches.
Usage: python3 scripts/golden_model.py
"""
import csv, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VREF, KP, KI, KD, SHIFT, DMAX = 2560, 2621, 262, 26214, 16, 400


def clamp(x, lo, hi):
    return lo if x < lo else hi if x > hi else x


class Pid:
    def __init__(self):
        self.integ, self.e_prev, self.duty = 0, 0, 0

    def step(self, adc):
        e = VREF - adc
        integ_n = clamp(self.integ + KI * e, 0, DMAX << SHIFT)
        u = (KP * e + KD * (e - self.e_prev) + integ_n) >> SHIFT   # arithmetic shift, like >>>
        duty = clamp(u, 0, DMAX)
        self.integ, self.e_prev, self.duty = integ_n, e, duty
        return duty


def main():
    path = os.path.join(ROOT, "results", "golden_log.csv")
    pid, bad, n = Pid(), 0, 0
    with open(path) as f:
        for row in csv.DictReader(f):
            n += 1
            exp = pid.step(int(row["adc"]))
            if exp != int(row["duty"]):
                bad += 1
                if bad <= 5:
                    print(f"MISMATCH tick {n}: adc={row['adc']} rtl={row['duty']} golden={exp}")
    print(f"golden model: {n} ticks compared, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
