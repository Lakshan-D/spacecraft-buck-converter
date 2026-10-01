#!/usr/bin/env python3
"""Draw the power-stage schematic (docs/schematic.png). Needs: pip install schemdraw"""
import os
import schemdraw
import schemdraw.elements as elm

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
with schemdraw.Drawing(show=False) as d:
    d.config(unit=2.5, fontsize=10)
    d += elm.Dot(open=True).label("Vin 22-36 V", loc="left")
    d += elm.Line().right(1)
    d += elm.Dot()
    d.push()
    d += elm.Capacitor().down().label("Cin 20 uF", loc="bottom")
    d += elm.Ground()
    d.pop()
    d += elm.Line().right(0.5)
    d += elm.Switch().right().label("S1 (PWM)", loc="top")
    d += elm.Dot()
    d.push()
    d += elm.Diode().down().reverse().label("D1", loc="right")
    d += elm.Ground()
    d.pop()
    d += elm.Inductor2().right().label("L1 22 uH", loc="top")
    d += elm.Dot()
    d.push()
    d += elm.Capacitor().down().label("Cout 47 uF", loc="bottom")
    d += elm.Ground()
    d.pop()
    d += elm.Line().right(1)
    d += elm.Dot(open=True).label("Vout 5 V / 3 A", loc="right")
    d.save(os.path.join(ROOT, "docs", "schematic.png"), dpi=150)
