#!/usr/bin/env python3
"""Run the buck converter netlists in ngspice, sweep corners, make plots and tables.

Usage:  python3 scripts/run_spice.py
Needs:  ngspice, numpy, matplotlib
Output: results/spice_corners.csv, results/spice_summary.md, results/*.png
"""
import re, subprocess, tempfile, os, csv
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPICE = os.path.join(ROOT, "spice")
RES = os.path.join(ROOT, "results")
os.makedirs(RES, exist_ok=True)
_trapz = getattr(np, "trapezoid", None) or np.trapz
FSW = 200e3
VOUT_TARGET = 5.0


def run(netlist, params, vectors, tstop=2e-3):
    """Run ngspice with overridden .param values. Returns dict name -> (t, y)."""
    txt = open(os.path.join(SPICE, netlist)).read()
    for k, v in params.items():
        txt = re.sub(rf"(?im)^\.param\s+{k}\s*=.*$", f".param {k}={v}", txt)
    txt = txt.replace(".end\n", "")
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "o.txt")
        txt += f"\n.control\nrun\nset wr_singlescale\nwrdata {out} {' '.join(vectors)}\n.endc\n.end\n"
        cir = os.path.join(d, "n.cir")
        open(cir, "w").write(txt)
        subprocess.run(["ngspice", "-b", cir], capture_output=True, text=True, check=True)
        raw = np.loadtxt(out)
    t = raw[:, 0]
    return {v: raw[:, i + 1] for i, v in enumerate(vectors)}, t


def window(t, y, t0, t1):
    m = (t >= t0) & (t <= t1)
    return t[m], y[m]


def tavg(t, y):
    return _trapz(y, t) / (t[-1] - t[0])


def measure(params):
    """Steady-state metrics over the last 40 switching cycles."""
    sig, t = run("buck_open_loop.cir", params, ["v(out)", "i(L1)", "i(Vsrc)", "v(vin)", "v(sw)"])
    t0, t1 = 2e-3 - 40 / FSW, 2e-3
    tw, vo = window(t, sig["v(out)"], t0, t1)
    _, il = window(t, sig["i(L1)"], t0, t1)
    _, isrc = window(t, sig["i(Vsrc)"], t0, t1)
    _, vin = window(t, sig["v(vin)"], t0, t1)
    _, vsw = window(t, sig["v(sw)"], t0, t1)
    rl = float(params.get("Rload", 1.667))
    pout = tavg(tw, vo * vo / rl)
    pin = tavg(tw, -isrc * 28.0 if "Vin" not in params else -isrc * float(params["Vin"]))
    return dict(
        vo=tavg(tw, vo), vo_ripple_mv=(vo.max() - vo.min()) * 1e3,
        il_avg=tavg(tw, il), il_pp=il.max() - il.min(), il_peak=il.max(),
        vsw_max=vsw.max(), eff=100 * pout / pin, pout=pout, pin=pin,
    )


def tune_duty(base):
    """Find the duty cycle that gives 5.0V (stands in for a perfect closed loop)."""
    d = VOUT_TARGET / float(base["Vin"]) * 1.06
    for _ in range(5):
        m = measure({**base, "Duty": round(d, 5)})
        d *= VOUT_TARGET / m["vo"]
    m = measure({**base, "Duty": round(d, 5)})
    return round(d, 5), m


# Temperature / tolerance corners (assumed, documented in docs/design_note.md)
PARTS = {
    "cold": dict(RonFET=0.035, Rdcr=0.017, Resr=0.015),
    "typ": dict(RonFET=0.05, Rdcr=0.02, Resr=0.005),
    "hot": dict(RonFET=0.075, Rdcr=0.026, Resr=0.005),
}


def corners():
    rows = []
    for vin in (22, 28, 36):
        for iout in (0.3, 3.0):
            for pname in ("cold", "typ", "hot"):
                base = dict(Vin=vin, Rload=round(VOUT_TARGET / iout, 4), **PARTS[pname])
                d, m = tune_duty(base)
                rows.append(dict(vin=vin, iout=iout, part=pname, duty=d, **m))
                print(f"Vin={vin} Iout={iout} {pname}: D={d} eff={m['eff']:.1f}% ripple={m['vo_ripple_mv']:.1f}mV")
    return rows


def efficiency_curve():
    loads = [0.3, 0.6, 1.0, 1.5, 2.0, 2.5, 3.0]
    eff = []
    for iout in loads:
        base = dict(Vin=28, Rload=round(VOUT_TARGET / iout, 4), **PARTS["typ"])
        _, m = tune_duty(base)
        eff.append(m["eff"])
    return loads, eff


def plots(rows, d_nom):
    # 1. Steady state
    sig, t = run("buck_open_loop.cir", dict(Duty=d_nom), ["v(out)", "i(L1)", "v(sw)"])
    t0, t1 = 1.9e-3, 1.9e-3 + 4 / FSW
    fig, ax = plt.subplots(3, 1, figsize=(8, 7), sharex=True)
    for a, k, lab in zip(ax, ["v(sw)", "i(L1)", "v(out)"], ["Switch node (V)", "Inductor current (A)", "Output voltage (V)"]):
        tt, yy = window(t, sig[k], t0, t1)
        a.plot((tt - t0) * 1e6, yy, lw=1.2)
        a.set_ylabel(lab)
        a.grid(alpha=0.3)
    ax[-1].set_xlabel("Time (us)")
    ax[0].set_title("Steady state, Vin = 28 V, Iout = 3 A (open loop, fixed duty)")
    fig.tight_layout()
    fig.savefig(os.path.join(RES, "spice_steady_state.png"), dpi=130)
    plt.close(fig)

    # 2. Load step
    sig, t = run("buck_load_step.cir", dict(Duty=d_nom), ["v(out)"])
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.plot(t * 1e3, sig["v(out)"], lw=0.9)
    ax.axvline(1.0, color="r", ls="--", lw=0.8, label="load step 0.3 A to 3 A")
    ax.set_xlabel("Time (ms)")
    ax.set_ylabel("Vout (V)")
    ax.set_title("Open-loop load step: Vout is off target and rings (why we need a controller)")
    ax.grid(alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(RES, "spice_load_step_open_loop.png"), dpi=130)
    plt.close(fig)

    # 3. Efficiency
    loads, eff = efficiency_curve()
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.plot(loads, eff, "o-")
    ax.set_xlabel("Load current (A)")
    ax.set_ylabel("Efficiency (%)")
    ax.set_title("Efficiency vs load, Vin = 28 V, Vout = 5 V")
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(RES, "spice_efficiency.png"), dpi=130)
    plt.close(fig)
    return loads, eff


def main():
    rows = corners()
    with open(os.path.join(RES, "spice_corners.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: (round(v, 4) if isinstance(v, float) else v) for k, v in r.items()})
    nom = next(r for r in rows if r["vin"] == 28 and r["iout"] == 3.0 and r["part"] == "typ")
    loads, eff = plots(rows, nom["duty"])

    # Open-loop line regulation at the nominal duty (no feedback)
    line = []
    for vin in (22, 28, 36):
        m = measure(dict(Vin=vin, Duty=nom["duty"], Rload=1.667, **PARTS["typ"]))
        line.append((vin, m["vo"]))

    worst_rip = max(r["vo_ripple_mv"] for r in rows)
    worst_ilpk = max(r["il_peak"] for r in rows)
    worst_vsw = max(r["vsw_max"] for r in rows)
    with open(os.path.join(RES, "spice_summary.md"), "w") as f:
        f.write("# SPICE results (auto-generated by scripts/run_spice.py)\n\n")
        f.write(f"Nominal point (28 V in, 3 A out, typical parts): D = {nom['duty']}, "
                f"Vout = {nom['vo']:.3f} V, ripple = {nom['vo_ripple_mv']:.1f} mV pk-pk, "
                f"inductor ripple = {nom['il_pp']:.2f} A pk-pk, efficiency = {nom['eff']:.1f} %.\n\n")
        f.write("## Corner table (duty tuned per corner to hold 5.00 V)\n\n")
        f.write("| Vin (V) | Iout (A) | Parts | Duty | Vout (V) | Ripple (mV pk-pk) | IL pk (A) | Vsw max (V) | Eff (%) |\n")
        f.write("|---|---|---|---|---|---|---|---|---|\n")
        for r in rows:
            f.write(f"| {r['vin']} | {r['iout']} | {r['part']} | {r['duty']} | {r['vo']:.3f} | "
                    f"{r['vo_ripple_mv']:.1f} | {r['il_peak']:.2f} | {r['vsw_max']:.1f} | {r['eff']:.1f} |\n")
        f.write("\n## Open-loop line regulation (duty fixed at nominal)\n\n| Vin (V) | Vout (V) |\n|---|---|\n")
        for vin, vo in line:
            f.write(f"| {vin} | {vo:.3f} |\n")
        f.write(f"\nWorst-case ripple {worst_rip:.1f} mV, worst-case inductor peak {worst_ilpk:.2f} A, "
                f"worst-case switch node {worst_vsw:.1f} V.\n")
        f.write("\n## Efficiency vs load (28 V in)\n\n| Iout (A) | Eff (%) |\n|---|---|\n")
        for l, e in zip(loads, eff):
            f.write(f"| {l} | {e:.1f} |\n")
    print("done")


if __name__ == "__main__":
    main()
