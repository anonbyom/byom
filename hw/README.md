# BYOM hardware

RTL, matrix-unit integration flow and build scripts of BYOM's TPU-style accelerator for the AMD Alveo U55C.

`rtl/`: the base (default MXU `rtl/mxu/array/mxu.sv`, DSP PE, fabric PE).
`examples/<unit>/`: integrated units.
`fpga/` kernel wrapper, builder, floorplans, image configurations.
`tools/byom/` the flow.

```sh
python3 tools/byom/integrate.py tpu_2mxu_dsp_int4  # build configuration + compiler description
python3 fpga/scripts/build.py xclbin --config fpga/config/variants/tpu_2mxu_dsp_int4.toml \
    --freq 330 --jobs 8 --set VMEM_DEPTH=131072 --output build/tpu_2mxu_dsp_int4
```

Examples by level: 
- Arithmetic: `examples/ultra-dsp`, `examples/xtramac`, `examples/exmy`
- PE:         `examples/kan-sas`
- MXU:        `examples/gemmini`.
