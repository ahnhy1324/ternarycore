#!/usr/bin/env python3
"""Validate and regenerate the theory-closed KV-cache v0.3 page artifacts."""

from __future__ import annotations

import argparse
import csv
import json
import struct
import zlib
from pathlib import Path

import numpy as np

from packed5_page_codec import (
    CRCError,
    HEADER_BYTES,
    SCALE_FORMAT_UQ4_8,
    VECTOR_VALUES,
    CodecError,
    _stream_contract,
    _unpack_prefix_bits,
    build_page_stream,
    crc32_iso_hdlc,
    decode_page,
    decode_page_stream,
    encode_page,
    load_codebook,
    pack_scale_codes,
    parse_header,
    sha256_bytes,
    stream_statistics,
    unpack_raw,
    unpack_scale_codes,
    verify_offset_table,
)


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def decode_legacy_sample(record: bytes, is_v: bool,
                         codebook: dict) -> tuple[np.ndarray, object]:
    """Decode the imported payload-only-CRC sample without accepting its CRC."""

    header = parse_header(record)
    if header.is_v != is_v:
        raise AssertionError("legacy K/V identity mismatch")
    payload = record[HEADER_BYTES:HEADER_BYTES + header.payload_bytes]
    if zlib.crc32(payload) & 0xFFFFFFFF != header.crc32:
        raise AssertionError("legacy payload-only CRC does not verify")
    _, bits, table, max_length = _stream_contract(is_v, codebook)
    if header.raw:
        codes = unpack_raw(payload, header.token_count, bits)
    else:
        codes = _unpack_prefix_bits(
            payload, header.token_count * VECTOR_VALUES, table, max_length
        ).reshape(header.token_count, VECTOR_VALUES)
    return codes, header


def expect_failure(name: str, expected: type[Exception], callback,
                   rows: list[dict]) -> None:
    try:
        callback()
    except expected as error:
        rows.append({
            "test": name,
            "status": "PASS",
            "expected_exception": expected.__name__,
            "observed_exception": type(error).__name__,
            "detail": str(error),
        })
        return
    except Exception as error:  # pragma: no cover - reported in result artifact
        rows.append({
            "test": name,
            "status": "FAIL",
            "expected_exception": expected.__name__,
            "observed_exception": type(error).__name__,
            "detail": str(error),
        })
        raise
    rows.append({
        "test": name,
        "status": "FAIL",
        "expected_exception": expected.__name__,
        "observed_exception": "none",
        "detail": "corruption was not rejected",
    })
    raise AssertionError(f"{name}: corruption was not rejected")


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--imported-codec", type=Path,
        default=repo.parent / "kv-v03-theory-closure-review-35fb5881" /
        "kv_v03_theory_closure_20260816" / "source_v03" / "codec")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" / "codec")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    required = [
        "sample_k_page64.bin", "sample_v_page64.bin",
        "sample_k_scale_uq4_8_12b.bin", "sample_v_scale_uq4_8_12b.bin",
    ]
    missing = [name for name in required if not (args.imported_codec / name).is_file()]
    if missing:
        raise FileNotFoundError(f"imported codec sample is incomplete: {missing}")

    codebook = load_codebook()
    sample_rows = []
    generated = {}
    decoded_samples = {}
    for stream, is_v in (("K", False), ("V", True)):
        legacy_record = (args.imported_codec / f"sample_{stream.lower()}_page64.bin").read_bytes()
        legacy_scale_slice = (
            args.imported_codec /
            f"sample_{stream.lower()}_scale_uq4_8_12b.bin").read_bytes()
        codes, legacy_header = decode_legacy_sample(legacy_record, is_v, codebook)
        scales = unpack_scale_codes(
            legacy_scale_slice, legacy_header.token_count, SCALE_FORMAT_UQ4_8)
        decoded_samples[stream] = (codes, scales)

        closed_crc = crc32_iso_hdlc(
            (legacy_record[:8], legacy_record[12:], legacy_scale_slice))
        sample_rows.append({
            "stream": stream,
            "legacy_record_bytes": len(legacy_record),
            "legacy_payload_bytes": legacy_header.payload_bytes,
            "legacy_payload_only_crc32": f"0x{legacy_header.crc32:08x}",
            "closed_contract_crc32": f"0x{closed_crc:08x}",
            "legacy_crc_is_closed_contract": legacy_header.crc32 == closed_crc,
            "decoded_tokens": codes.shape[0],
            "decoded_values_per_token": codes.shape[1],
            "scale_slice_bytes": len(legacy_scale_slice),
        })

        for page_tokens, repeat in ((64, 1), (128, 2)):
            page_codes = np.concatenate([codes] * repeat)
            page_scales = np.concatenate([scales] * repeat)
            page_stream = build_page_stream(
                page_codes, page_scales, page_tokens=page_tokens, is_v=is_v,
                scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook)
            scale_plane = pack_scale_codes(page_scales, SCALE_FORMAT_UQ4_8)
            actual_codes, actual_scales = decode_page_stream(
                page_stream, scale_plane, page_tokens=page_tokens, is_v=is_v,
                scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook,
                total_tokens=len(page_scales))
            np.testing.assert_array_equal(actual_codes, page_codes)
            np.testing.assert_array_equal(actual_scales, page_scales)

            stem = f"sample_{stream.lower()}_page{page_tokens}_closed"
            paths = {
                "stream": args.output / f"{stem}.bin",
                "scales": args.output / f"{stem}_scale_uq4_8_12b.bin",
                "offsets": args.output / f"{stem}_offsets_u32.bin",
            }
            paths["stream"].write_bytes(page_stream.data)
            paths["scales"].write_bytes(scale_plane)
            paths["offsets"].write_bytes(page_stream.offset_table)
            statistics = stream_statistics(
                page_stream, len(page_scales), 5 if is_v else 4,
                len(scale_plane))
            generated[f"{stream}_page{page_tokens}"] = {
                "page_tokens": page_tokens,
                "stream": stream,
                "crc_contract": "CRC32/ISO-HDLC(header[0:8] || payload || scale_slice)",
                "offset_table_crc_contract": "CRC32/ISO-HDLC(offset_table)",
                "offset_table_crc32": f"0x{page_stream.offset_table_crc32:08x}",
                "offsets": list(page_stream.offsets),
                "statistics": statistics,
                "files": {
                    name: {
                        "path": str(path.relative_to(args.output.parent)).replace("\\", "/"),
                        "bytes": path.stat().st_size,
                        "sha256": sha256_bytes(path.read_bytes()),
                    }
                    for name, path in paths.items()
                },
            }

    fault_rows: list[dict] = []
    k_codes, k_scales = decoded_samples["K"]
    reference = build_page_stream(
        k_codes, k_scales, page_tokens=64, is_v=False,
        scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook)
    record = reference.pages[0].record
    scale_slice = reference.pages[0].scale_slice

    damaged = bytearray(record); damaged[2] ^= 1
    expect_failure(
        "header_first8_bit_flip", CRCError,
        lambda: decode_page(bytes(damaged), scale_slice, codebook=codebook),
        fault_rows)
    damaged = bytearray(record); damaged[HEADER_BYTES + 7] ^= 0x20
    expect_failure(
        "payload_bit_flip", CRCError,
        lambda: decode_page(bytes(damaged), scale_slice, codebook=codebook),
        fault_rows)
    damaged_scale = bytearray(scale_slice); damaged_scale[3] ^= 0x04
    expect_failure(
        "scale_slice_bit_flip", CRCError,
        lambda: decode_page(record, bytes(damaged_scale), codebook=codebook),
        fault_rows)
    damaged = bytearray(record); damaged[8] ^= 0x01
    expect_failure(
        "stored_crc_bit_flip", CRCError,
        lambda: decode_page(bytes(damaged), scale_slice, codebook=codebook),
        fault_rows)
    expect_failure(
        "truncated_payload", CodecError,
        lambda: decode_page(record[:-1], scale_slice, codebook=codebook),
        fault_rows)
    damaged_offsets = bytearray(reference.offset_table)
    damaged_offsets[0] ^= 0x10
    expect_failure(
        "offset_table_bit_flip", CRCError,
        lambda: verify_offset_table(
            bytes(damaged_offsets), reference.offset_table_crc32,
            len(reference.data)),
        fault_rows)

    crc_disabled = encode_page(
        k_codes, k_scales, is_v=False,
        scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook,
        crc_enable=False)
    disabled_codes, disabled_scales, disabled_header = decode_page(
        crc_disabled.record, crc_disabled.scale_slice, codebook=codebook,
        crc_enable=False)
    np.testing.assert_array_equal(disabled_codes, k_codes)
    np.testing.assert_array_equal(disabled_scales, k_scales)
    if disabled_header.crc32 != 0:
        raise AssertionError("CRC-disabled page does not contain a zero CRC field")
    fault_rows.append({
        "test": "crc_disabled_roundtrip",
        "status": "PASS",
        "expected_exception": "none",
        "observed_exception": "none",
        "detail": "zero CRC field; integrity faults intentionally unprotected",
    })

    for stream, is_v, bits, value in (("K", False, 4, -7), ("V", True, 5, -15)):
        raw_codes = np.full((64, VECTOR_VALUES), value, dtype=np.int8)
        raw_scales = np.arange(1, 65, dtype=np.uint16)
        raw_stream = build_page_stream(
            raw_codes, raw_scales, page_tokens=64, is_v=is_v,
            scale_format_id=SCALE_FORMAT_UQ4_8, codebook=codebook)
        if not raw_stream.pages[0].header.raw:
            raise AssertionError(f"{stream} incompressible page did not fall back to raw")
        scale_plane = pack_scale_codes(raw_scales, SCALE_FORMAT_UQ4_8)
        actual_codes, actual_scales = decode_page_stream(
            raw_stream, scale_plane, page_tokens=64, is_v=is_v,
            total_tokens=64, codebook=codebook)
        np.testing.assert_array_equal(actual_codes, raw_codes)
        np.testing.assert_array_equal(actual_scales, raw_scales)
        fault_rows.append({
            "test": f"{stream.lower()}_raw_fallback_roundtrip",
            "status": "PASS",
            "expected_exception": "none",
            "observed_exception": "none",
            "detail": f"signed {bits}-bit LSB-reservoir raw page",
        })

    if crc32_iso_hdlc((b"123456789",)) != 0xCBF43926:
        raise AssertionError("CRC-32/ISO-HDLC check value mismatch")

    write_csv(args.output / "legacy_sample_crc_delta.csv", sample_rows)
    write_csv(args.output / "codec_fault_matrix.csv", fault_rows)
    result = {
        "evidence": "SOFTWARE-BIT-EXACT/v0.3-page-codec",
        "status": "PASS",
        "source_package": "kv-cache-v0.3-theory-closure-handoff-20260816.zip",
        "source_package_sha256": "35fb5881b7fc5fff05ac87e9c90594c542bb2396b03de1a4140757e07ca4525e",
        "legacy_contract_warning": (
            "Imported page64 samples use payload-only CRC and are not valid "
            "theory-closed pages; decoded symbols/scales were used to regenerate them."),
        "crc": {
            "name": "CRC-32/ISO-HDLC",
            "normal_polynomial": "0x04C11DB7",
            "reflected_polynomial": "0xEDB88320",
            "init": "0xFFFFFFFF",
            "xorout": "0xFFFFFFFF",
            "refin": True,
            "refout": True,
            "check_123456789": "0xCBF43926",
        },
        "generated": generated,
        "fault_tests": fault_rows,
        "fault_policy_for_rtl": (
            "sticky typed error; suppress decode/output; abort page; reload; "
            "never reinterpret a failed compressed page as raw"),
    }
    (args.output / "codec_validation.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": result["status"],
        "generated_profiles": sorted(generated),
        "fault_tests": len(fault_rows),
    }, indent=2))


if __name__ == "__main__":
    main()
