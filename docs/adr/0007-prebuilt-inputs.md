# 7. Prebuilt inputs accepted in v1

Status: proposed (reviewer questions Q1, Q2)

## Decision

These inputs are installed prebuilt: the TheRock rocm-sdk wheels (compiler and
math libraries), AOTriton kernel images downloaded by the torch build, and the
LLVM that Triton's build downloads. Everything we patch or ship is built from
source.
