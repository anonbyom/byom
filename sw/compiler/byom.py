import ctypes
import json
import os
import time
from pathlib import Path

import numpy as np


_L = ctypes.CDLL(os.environ.get("LIBBYOM_SO") or str(Path(__file__).resolve().parent / "libbyom.so"))
_p, _i64, _str = ctypes.c_void_p, ctypes.c_int64, ctypes.c_char_p
for _name, _res, _args in (
        ("byom_error", _str, []), ("byom_compile", _p, [_str, _str, _str]), ("byom_info", _str, [_p]),
        ("byom_log", _str, [_p]), ("byom_free", None, [_p]),
        ("byom_build", _p, [_p, ctypes.POINTER(_i64), ctypes.POINTER(ctypes.POINTER(ctypes.c_float)), _i64, ctypes.c_int]),
        ("byom_built_free", None, [_p]), ("byom_built_code", _i64, [_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_uint8))]),
        ("byom_built_image", _i64, [_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_uint16)), ctypes.POINTER(_i64)]),
        ("byom_built_cycles", _i64, [_p]), ("byom_built_listing", _str, [_p]),
        ("byom_built_report", _i64, [_p, _str, ctypes.c_int]),
        ("byom_built_output", _i64, [_p, _i64, ctypes.POINTER(ctypes.c_uint16), _i64,
                                     ctypes.POINTER(ctypes.POINTER(ctypes.c_float))]),
        ("byom_sidecar_view", _str, [_str]), ("byom_isa_error", _str, [])):
    getattr(_L, _name).restype, getattr(_L, _name).argtypes = _res, _args

def _check(value, failed=None):
    if value is None or value == failed:
        kind, _, text = _L.byom_error().decode().partition(": ")
        raise RuntimeError(f"{kind}: {text}")
    return value

def sidecar(image):
    if not isinstance(image, dict):
        p = Path(image)
        q = next((q for q in (p, Path(str(p) + ".json"), p.with_suffix(".json")) if q.suffix == ".json" and q.is_file()), None)
        if q is None:
            raise FileNotFoundError(f"no image description for {image} (IMAGE.xclbin.json)")
        image = json.loads(q.read_text())
    text = _L.byom_sidecar_view(json.dumps(image).encode())
    if text is None:
        raise ValueError(_L.byom_isa_error().decode())
    return json.loads(text)

class Program:
    def __init__(self, hlo, image, **options):
        self.info = sidecar(image)
        text = Path(hlo).read_text() if "\n" not in str(hlo) and Path(str(hlo)).is_file() else hlo
        t0 = time.time()
        self._h = _check(_L.byom_compile(str(text).encode(), json.dumps(self.info).encode(), json.dumps(options).encode()))
        self.compile_s = time.time() - t0
        meta = json.loads(_L.byom_info(self._h))
        self.params = {int(n): tuple(s) for n, s in meta["params"].items()}
        self.outputs = [tuple(s) for s in meta["outputs"]]
        self.kernels, self.gemms, self.row_passes = meta["kernels"], meta["gemms"], meta["row_passes"]
        self.loop, self.vmem_peak_rows = meta["loop"], meta["vmem_peak_rows"]
        self._b = self._cycles = None

    def __del__(self):
        if getattr(self, "_b", None):
            _L.byom_built_free(self._b)
        if getattr(self, "_h", None):
            _L.byom_free(self._h)

    def _build(self, args=None, overlay=False):
        args = {int(n): np.ascontiguousarray(a, np.float32) for n, a in (args or {}).items()}
        for n, a in args.items():
            if tuple(a.shape) != self.params[n]:
                raise ValueError(f"parameter {n}: shape {a.shape}, the module's is {self.params[n]}")
        numbers = (_i64 * len(args))(*args)
        data = (ctypes.POINTER(ctypes.c_float) * len(args))(*[a.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
                                                               for a in args.values()])
        return _check(_L.byom_build(self._h, numbers, data, len(args), int(overlay)))

    def _built(self):
        if self._b is None:
            self._b = self._build()
        return self._b

    @property
    def bundles(self):
        return len(self.code()) // self.info_bundle_bytes

    @property
    def info_bundle_bytes(self):
        return json.loads(_L.byom_info(self._h))["bundle_bytes"]

    @property
    def cycles(self):
        """Cycles on the image's timing model."""
        if self._cycles is None:
            b = self._build(None, 2)
            try:
                self._cycles = _check(_L.byom_built_cycles(b), -1)
            finally:
                _L.byom_built_free(b)
        return self._cycles

    @property
    def ms(self):
        c = self.info.get("clock_mhz")
        return round(self.cycles / c / 1e3, 4) if c else None

    def asm(self):
        return _check(_L.byom_built_listing(self._built())).decode()

    def log(self):
        return json.loads(_check(_L.byom_log(self._h)))

    def code(self, args=None, overlay=False):
        b = self._built() if args is None and not overlay else self._build(args, overlay)
        p = ctypes.POINTER(ctypes.c_uint8)()
        out = ctypes.string_at(p, _L.byom_built_code(b, ctypes.byref(p))) if _L.byom_built_code(b, ctypes.byref(p)) else b""
        if b is not self._b:
            _L.byom_built_free(b)
        return out

    def image(self, args=None):
        b = self._build(args)
        p, words = ctypes.POINTER(ctypes.c_uint16)(), _i64()
        rows = _check(_L.byom_built_image(b, ctypes.byref(p), ctypes.byref(words)), -1)
        out = np.ctypeslib.as_array(p, (rows, 32)).copy() if rows else np.zeros((0, 32), np.uint16)
        _L.byom_built_free(b)
        return out

    def read(self, out_rows):
        rows = np.ascontiguousarray(out_rows, np.uint16).reshape(-1, 32)
        res = []
        for i, dims in enumerate(self.outputs):
            p = ctypes.POINTER(ctypes.c_float)()
            n = _check(_L.byom_built_output(self._built(), i, rows.ctypes.data_as(ctypes.POINTER(ctypes.c_uint16)),
                                            len(rows), ctypes.byref(p)), -1)
            res.append(np.ctypeslib.as_array(p, (n,)).copy().reshape(dims))
        return res

    def save(self, out_dir):
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "program.bin").write_bytes(self.code())
        _check(_L.byom_built_report(self._built(), str(out).encode(), 1), -1)
        return out

    def __repr__(self):
        ms = f" = {self.ms} ms" if self.ms is not None else ""
        loop = f", looped {self.loop}x" if self.loop > 1 else ""
        return (f"{self.kernels} kernels ({self.gemms} GEMM, {self.row_passes} row passes){loop}, {self.bundles:,} "
                f"bundles, {self.cycles:,} cycles{ms}. compiled in {self.compile_s:.1f} s")

def compile(hlo, image, **options): return Program(hlo, image, **options)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Compile an HLO module for a BYOM image.")
    ap.add_argument("hlo")
    ap.add_argument("image", help="the image's sidecar: IMAGE.xclbin.json")
    ap.add_argument("-o", "--out", help="directory for summary.txt, program.asm, program.bin")
    a = ap.parse_args()
    p = compile(a.hlo, a.image)
    print(p)
    if a.out:
        print("wrote", p.save(a.out))
