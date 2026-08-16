#!/usr/bin/env python3
"""Generate static lookahead ROMs and page-decoder golden vectors."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from packed5_page_codec import (
    HEADER_BYTES,
    SCALE_FORMAT_UQ4_8,
    build_page_stream,
    decode_page,
    load_codebook,
    pack_scale_codes,
    parse_header,
    unpack_scale_codes,
)
from validate_v0_3_codec import decode_legacy_sample


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def lookahead_table(codes: dict[str, str]) -> np.ndarray:
    table = np.zeros(256, dtype=np.uint16)
    for prefix in range(256):
        bits = f"{prefix:08b}"
        matches = [(word, int(symbol)) for symbol, word in codes.items()
                   if bits.startswith(word)]
        if len(matches) != 1:
            raise AssertionError(
                f"8-bit prefix {bits} has {len(matches)} code matches")
        word, symbol = matches[0]
        table[prefix] = (1 << 9) | (len(word) << 5) | (symbol & 0x1F)
    return table


def write_hex(path: Path, values: np.ndarray, digits: int) -> None:
    path.write_text("".join(
        f"{int(value):0{digits}x}\n" for value in values.reshape(-1)),
        encoding="ascii")


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--imported-codec", type=Path,
        default=repo.parent / "kv-v03-theory-closure-review-35fb5881" /
        "kv_v03_theory_closure_20260816" / "source_v03" / "codec")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "codec" / "decoder_goldens")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    codebook = load_codebook()
    files = []

    for stream in ("K", "V"):
        table = lookahead_table(codebook[stream]["codes"])
        path = args.output / f"{stream.lower()}_lookahead_256x10.hex"
        write_hex(path, table, 3)
        files.append(path)

        legacy_page = (
            args.imported_codec / f"sample_{stream.lower()}_page64.bin").read_bytes()
        legacy_scales = (
            args.imported_codec /
            f"sample_{stream.lower()}_scale_uq4_8_12b.bin").read_bytes()
        codes, header = decode_legacy_sample(
            legacy_page, stream == "V", codebook)
        scales = unpack_scale_codes(
            legacy_scales, header.token_count, SCALE_FORMAT_UQ4_8)
        bits = 5 if stream == "V" else 4
        for page_tokens, repeats in ((64, 1), (128, 2)):
            page_codes = np.concatenate([codes] * repeats)
            page_scales = np.concatenate([scales] * repeats)
            encoded = build_page_stream(
                page_codes, page_scales, page_tokens=page_tokens,
                is_v=stream == "V", scale_format_id=SCALE_FORMAT_UQ4_8,
                codebook=codebook)
            page = encoded.pages[0]
            decoded_codes, decoded_scales, _ = decode_page(
                page.record, page.scale_slice, codebook=codebook,
                expected_is_v=stream == "V",
                expected_token_count=page_tokens)
            np.testing.assert_array_equal(decoded_codes, page_codes)
            np.testing.assert_array_equal(decoded_scales, page_scales)
            stem = f"{stream.lower()}_compressed_page{page_tokens}"
            paths = {
                "record": args.output / f"{stem}_record_bytes.hex",
                "payload": args.output / f"{stem}_payload_bytes.hex",
                "scales": args.output / f"{stem}_scale_bytes.hex",
                "codes": args.output / f"{stem}_expected_codes.hex",
                "scale_codes": args.output / f"{stem}_expected_scale_codes.hex",
            }
            write_hex(paths["record"], np.frombuffer(page.record, dtype=np.uint8), 2)
            write_hex(paths["payload"], np.frombuffer(page.payload, dtype=np.uint8), 2)
            write_hex(paths["scales"], np.frombuffer(page.scale_slice, dtype=np.uint8), 2)
            write_hex(paths["codes"], decoded_codes.view(np.uint8), 2)
            write_hex(paths["scale_codes"], decoded_scales, 3)
            files.extend(paths.values())

        raw_codes = np.full((64, 128), -15 if stream == "V" else -7,
                            dtype=np.int8)
        raw_scales = np.arange(1, 65, dtype=np.uint16)
        raw = build_page_stream(
            raw_codes, raw_scales, page_tokens=64, is_v=stream == "V",
            scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook)
        if not raw.pages[0].header.raw:
            raise AssertionError("raw golden did not select whole-page fallback")
        raw_page = raw.pages[0]
        for suffix, values, digits in (
            ("record_bytes", np.frombuffer(raw_page.record, dtype=np.uint8), 2),
            ("payload_bytes", np.frombuffer(raw_page.payload, dtype=np.uint8), 2),
            ("scale_bytes", np.frombuffer(raw_page.scale_slice, dtype=np.uint8), 2),
            ("expected_codes", raw_codes.view(np.uint8), 2),
            ("expected_scale_codes", raw_scales, 3),
        ):
            path = args.output / f"{stream.lower()}_raw_page64_{suffix}.hex"
            write_hex(path, values, digits)
            files.append(path)

    manifest = {
        "evidence": "SOFTWARE-BIT-EXACT/v0.3-decoder-goldens",
        "status": "PASS",
        "lookahead_entry": {
            "bits": 10,
            "layout": "valid[9] | length[8:5] | signed_symbol_twos_complement[4:0]",
            "entries_per_stream": 256,
        },
        "files": [
            {
                "path": path.name,
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in sorted(set(files))
        ],
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": "PASS", "files": len(files),
        "output": str(args.output.resolve()),
    }, indent=2))


if __name__ == "__main__":
    main()
