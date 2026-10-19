#!/usr/bin/env python3
"""Bit-exact Python golden model of rtl/pid_ctrl.v.

Reads results/golden_log.csv (Vout and Vin ADC codes at each control tick, duty the
RTL produced), re-computes the duty with integer maths and checks every single
sample matches.
Usage: python3 scripts/golden_model.py [--ff 0|1] [--ss STEP]
Defaults match the RTL defaults (feedforward on, soft start 16 codes per tick).
"""
import argparse, csv, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VREF, KP, KI, KD, SHIFT, DMAX = 2560, 6554, 524, 104858, 16, 400
PERIOD, VIN_CPV, ADC_CPV = 500, 100, 512


def clamp(x, lo, hi):
    return lo if x < lo else hi if x > hi else x


class Pid:
    def __init__(self, ff_en=1, ss_step=16):
        self.ff_en, self.ss_step = ff_en, ss_step
        self.integ, self.e_prev, self.duty, self.ref = 0, 0, 0, 0

    def step(self, adc, vin):
        # soft start ramp (ss_step = 0 means the reference is VREF from the first tick)
        if self.ss_step == 0:
            ref_n = VREF
        else:
            ref_n = VREF if self.ref + self.ss_step >= VREF else self.ref + self.ss_step
        e = ref_n - adc
        lo = -(DMAX << SHIFT) if self.ff_en else 0
        integ_n = clamp(self.integ + KI * e, lo, DMAX << SHIFT)
        # Vin feedforward: duty counts = ref * PERIOD * VIN_CPV / (ADC_CPV * vin)
        ff = 0
        den = ADC_CPV * vin
        if self.ff_en and den != 0:
            ff = min((ref_n * PERIOD * VIN_CPV) // den, DMAX)
        u = ((KP * e + KD * (e - self.e_prev) + integ_n) >> SHIFT) + ff   # arithmetic shift, like >>>
        duty = clamp(u, 0, DMAX)
        self.integ, self.e_prev, self.duty, self.ref = integ_n, e, duty, ref_n
        return duty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ff", type=int, default=1, help="Vin feedforward on (1) or off (0)")
    ap.add_argument("--ss", type=int, default=16, help="soft start step, ADC codes per tick (0 = off)")
    ap.add_argument("--log", default=os.path.join(ROOT, "results", "golden_log.csv"))
    args = ap.parse_args()
    path = args.log
    pid, bad, n = Pid(args.ff, args.ss), 0, 0
    with open(path) as f:
        for row in csv.DictReader(f):
            n += 1
            exp = pid.step(int(row["adc"]), int(row["vin"]))
            if exp != int(row["duty"]):
                bad += 1
                if bad <= 5:
                    print(f"MISMATCH tick {n}: adc={row['adc']} vin={row['vin']} rtl={row['duty']} golden={exp}")
    print(f"golden model: {n} ticks compared, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
