# RTL Golden Vector Contract v0.1

This package freezes transport/packing only. It intentionally does NOT freeze
the scale binary point or softmax arithmetic before real-model validation.

## Input
- Q: signed INT8, D elements
- K: symmetric signed INT4, T x D
- V: symmetric signed INT4, T x D
- scales: raw little-endian uint16 codes

## INT4 packing
Elements `(x[0], x[1])` become one byte:
`byte = (x[0] & 0xF) | ((x[1] & 0xF) << 4)`.

Canonical mathematical values are -7..+7.
Nibble `0x8` is reserved and must trigger an assertion/error in strict testbenches.

## Expected QK
`expected_qk_i32.bin` contains T little-endian signed int32 values:
`sum_j int8(Q[j]) * int4(K[token,j])`.

This is an arithmetic transport sanity vector, before scale multiplication,
1/sqrt(D), masking, softmax, or AV.
