#!/usr/bin/env python3
"""Fast invariants for the reusable KV quantization reference."""

import numpy as np

from kv_quant_reference import (
    DitherRequest,
    hadamard_blocks,
    make_dataset,
    quantize_symmetric,
    scale_metadata_bytes_per_token,
)


def main() -> None:
    q, k, _ = make_dataset(1234, "outliers_1pct_x10", 2, 7)
    q_again, k_again, _ = make_dataset(1234, "outliers_1pct_x10", 2, 7)
    assert np.array_equal(q, q_again)
    assert np.array_equal(k, k_again)

    for block in (None, 4, 8, 16, 32, 64):
        transformed = hadamard_blocks(k, block)
        recovered = hadamard_blocks(transformed, block)
        assert np.allclose(recovered, k, rtol=2.0e-6, atol=2.0e-6)

    for granularity, group_size in (("run", None), ("token", None),
                                    ("group", 32), ("group", 16),
                                    ("group", 8)):
        quant = quantize_symmetric(k, 4, granularity=granularity,
                                   group_size=group_size, scale_format="Q8.8")
        assert quant.codes.shape == k.shape
        assert np.min(quant.codes) >= -7 and np.max(quant.codes) <= 7
        assert np.all(np.isfinite(quant.dequant))

    seen_metadata = {}

    def zero_dither(request: DitherRequest) -> np.ndarray:
        seen_metadata.update(request.metadata)
        return np.zeros(request.shape, dtype=np.float32)

    plain = quantize_symmetric(k, 4, granularity="token")
    dithered = quantize_symmetric(
        k, 4, granularity="token", dither=zero_dither,
        dither_metadata={"token": 7, "head": 3})
    assert np.array_equal(plain.codes, dithered.codes)
    assert seen_metadata == {"token": 7, "head": 3}

    assert scale_metadata_bytes_per_token("token", 64, 512, 16) == 2
    assert scale_metadata_bytes_per_token("group", 64, 512, 16, 16) == 8
    assert scale_metadata_bytes_per_token("group", 64, 512, 16, 8) == 16
    assert scale_metadata_bytes_per_token("run", 64, 512, 16) == 2 / 512
    print("KV quantization reference PASS")


if __name__ == "__main__":
    main()
