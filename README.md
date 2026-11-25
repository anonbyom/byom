# BYOM: Bring Your Own Matrix Unit to a TPU-Style FPGA Accelerator

TPU-style accelerator for the AMD Alveo U55C with replaceable matrix units, PEs and arithmetic, and a compiler that runs PyTorch models on it.

- `hw/`: accelerator RTL, integration flow, unit examples, paper images. See `hw/README.md`.
- `sw/`: libbyom compiler and runtime, evaluation scripts. See `sw/README.md`.
