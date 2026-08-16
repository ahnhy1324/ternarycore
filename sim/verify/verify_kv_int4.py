#!/usr/bin/env python3
"""Executable v0.1 INT4 KV-cache numerical and packing contract."""

HEAD_DIM = 64
KV_BITS = 4
VECTOR_BYTES = 32
MAX_CONTEXT = 4096
REGRESSION_LENGTHS = (
    1, 7, 63, 64, 65,
    127, 128, 129,
    511, 512, 513,
    1023, 1024, 1025,
    4095, 4096,
)


def signed_int4(code: int) -> int:
    code &= 0xF
    return code - 16 if code & 8 else code


def k_value(token: int, dim: int) -> int:
    return signed_int4(token * 3 + dim * 5 + 8)


def q_value(dim: int) -> int:
    return dim % 9 - 4


def pack_k(token: int) -> bytes:
    values = [k_value(token, dim) & 0xF for dim in range(HEAD_DIM)]
    return bytes(values[i] | (values[i + 1] << 4) for i in range(0, HEAD_DIM, 2))


def unpack_k(data: bytes) -> list[int]:
    assert len(data) == VECTOR_BYTES
    result: list[int] = []
    for byte in data:
        result.extend((signed_int4(byte), signed_int4(byte >> 4)))
    return result


def qk_logit(token: int, scale_q8_8: int = 0x0100) -> int:
    # The RTL leaves the binary point in the result: integer Q times Q8.8 K.
    return sum(q_value(dim) * k_value(token, dim) * scale_q8_8
               for dim in range(HEAD_DIM))


def vector_address(base: int, token: int) -> int:
    return base + token * VECTOR_BYTES


def main() -> None:
    base = 0x8000_1000
    for length in REGRESSION_LENGTHS:
        assert 1 <= length <= MAX_CONTEXT
        for token in {0, length - 1}:
            packed = pack_k(token)
            assert unpack_k(packed) == [k_value(token, dim) for dim in range(HEAD_DIM)]
            assert vector_address(base, token) == base + (token << 5)
            result = qk_logit(token)
            assert -(1 << 31) <= result < (1 << 31)
    # Signed extrema and nibble order are part of the ABI.
    assert signed_int4(0x7) == 7
    assert signed_int4(0x8) == -8
    assert unpack_k(pack_k(0))[:4] == [-8, -3, 2, 7]
    print("KV INT4 reference PASS:", ",".join(map(str, REGRESSION_LENGTHS)))


if __name__ == "__main__":
    main()
