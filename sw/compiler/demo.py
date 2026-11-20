#!/usr/bin/env python3
"""The BYOM compiler on its own takes an HLO program and target description and outputs program's kernels, VLIW code and perf
metrics based on it timing model.

    python3 demo.py [TARGET.json]

TARGET is a description the hardware's integration flow writes (hw/fpga/config/sidecars/).
"""
import sys
from pathlib import Path

import byom

DEFAULT = Path(__file__).resolve().parents[2] / "hw/fpga/config/sidecars/tpu_1mxu_dsp_mxfp4.json"
TARGET = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    

# y = relu(x @ w1 + b1) @ w2
HLO = """
HloModule mlp

ENTRY main (x: f32[128,256], w1: f32[256,1024], b1: f32[1024], w2: f32[1024,256]) -> f32[128,256] {
  x = f32[128,256] parameter(0)
  w1 = f32[256,1024] parameter(1)
  b1 = f32[1024] parameter(2)
  w2 = f32[1024,256] parameter(3)
  h = f32[128,1024] dot(x, w1), lhs_contracting_dims={1}, rhs_contracting_dims={0}
  b = f32[128,1024] broadcast(b1), dimensions={1}
  hb = f32[128,1024] add(h, b)
  zero = f32[] constant(0)
  zeros = f32[128,1024] broadcast(zero), dimensions={}
  r = f32[128,1024] maximum(hb, zeros)
  ROOT y = f32[128,256] dot(r, w2), lhs_contracting_dims={1}, rhs_contracting_dims={0}
}
"""

p = byom.compile(HLO, TARGET)
print(p)

out = p.save("demo-out")                # also each kernel's code, the schedule and the whole listing
print(f"\n{out}/summary.txt, the kernels:")
print((out / "summary.txt").read_text())

asm = p.asm().splitlines()
loop = next(i for i, line in enumerate(asm) if line.endswith(":") and "_body" in line)
print(f"{out}/program.asm, the first matmul's loop:")
print("\n".join(asm[loop:loop + 16]))
