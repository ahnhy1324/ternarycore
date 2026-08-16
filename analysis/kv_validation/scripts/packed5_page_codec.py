#!/usr/bin/env python3
"""Bit-exact software contract for the KV-cache v0.3 PACKED5 page codec.

The theory-closure handoff supersedes the original page64 sample in one
important respect: a page CRC covers ``header[0:8] || payload || scale_slice``.
The original sample covered only the payload.  This module implements the
closed contract and supports both 64- and 128-token pages.

Compressed prefix-code bits are emitted in code-string order, most-significant
bit first within each byte.  Raw signed codes and 12-bit scale values use a
least-significant-bit-first reservoir, matching the handoff's unpacker and
scale-plane contract.  Pages are little-endian and start on 16-byte boundaries.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import struct
import zlib
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np


MAGIC_VERSION = 0xC303
HEADER = struct.Struct("<HBBHBBI")
HEADER_BYTES = HEADER.size
ALIGNMENT_BYTES = 16
FLAG_RAW = 1 << 0
FLAG_V = 1 << 1
CODEBOOK_STATIC_V1 = 1
SCALE_FORMAT_UQ4_8 = 1
SCALE_FORMAT_UQ5_11 = 2
VECTOR_VALUES = 128
VALID_PAGE_TOKENS = (64, 128)


class CodecError(ValueError):
    """A malformed page, checksum failure, or contract violation."""


class CRCError(CodecError):
    """Page or offset-table integrity check failed."""


@dataclasses.dataclass(frozen=True)
class PageHeader:
    raw: bool
    is_v: bool
    token_count: int
    payload_bytes: int
    codebook_id: int
    scale_format_id: int
    crc32: int


@dataclasses.dataclass(frozen=True)
class EncodedPage:
    record: bytes
    payload: bytes
    scale_slice: bytes
    header: PageHeader
    compressed_payload_bytes: int
    raw_payload_bytes: int


@dataclasses.dataclass(frozen=True)
class PageStream:
    data: bytes
    offsets: tuple[int, ...]
    offset_table: bytes
    offset_table_crc32: int
    pages: tuple[EncodedPage, ...]


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def crc32_iso_hdlc(parts: Iterable[bytes]) -> int:
    """CRC-32/ISO-HDLC as exposed by zlib (check value 0xCBF43926)."""

    crc = 0
    for part in parts:
        crc = zlib.crc32(part, crc)
    return crc & 0xFFFFFFFF


def _default_codebook_path() -> Path:
    return (Path(__file__).resolve().parents[1] / "v0_3" / "codec" /
            "packed5_static_codebook.json")


def load_codebook(path: Path | None = None) -> dict:
    source = path or _default_codebook_path()
    result = json.loads(source.read_text(encoding="utf-8"))
    if result.get("schema") != "kv-v0.3-packed5-page-prefix-v1":
        raise CodecError(f"unsupported codebook schema in {source}")
    for stream in ("K", "V"):
        codes = result[stream]["codes"]
        _validate_prefix_codes(codes, int(result[stream]["max_code_length"]))
    return result


def _validate_prefix_codes(codes: dict[str, str], max_length: int) -> None:
    words = list(codes.values())
    if len(words) != len(set(words)):
        raise CodecError("duplicate prefix code")
    if any(not word or set(word) - {"0", "1"} for word in words):
        raise CodecError("prefix codes must be non-empty binary strings")
    if max(map(len, words)) != max_length:
        raise CodecError("declared maximum code length does not match table")
    for left in words:
        for right in words:
            if left != right and right.startswith(left):
                raise CodecError(f"non-prefix-free table: {left} prefixes {right}")


def _require_codes(codes: np.ndarray, bits: int) -> np.ndarray:
    values = np.asarray(codes)
    if values.ndim != 2 or values.shape[1] != VECTOR_VALUES:
        raise CodecError(
            f"codes must be [tokens,{VECTOR_VALUES}], got {values.shape}")
    if not np.issubdtype(values.dtype, np.integer):
        raise CodecError("codes must have an integer dtype")
    minimum = -(1 << (bits - 1)) + 1
    maximum = (1 << (bits - 1)) - 1
    if values.size and (int(values.min()) < minimum or int(values.max()) > maximum):
        raise CodecError(
            f"{bits}-bit narrow-range codes must be in [{minimum},{maximum}]")
    return values.astype(np.int8, copy=False)


def _pack_lsb_values(values: np.ndarray, width: int) -> bytes:
    mask = (1 << width) - 1
    output = bytearray()
    reservoir = 0
    available = 0
    for value in np.asarray(values).reshape(-1):
        reservoir |= (int(value) & mask) << available
        available += width
        while available >= 8:
            output.append(reservoir & 0xFF)
            reservoir >>= 8
            available -= 8
    if available:
        output.append(reservoir & 0xFF)
    return bytes(output)


def _unpack_lsb_values(data: bytes, count: int, width: int,
                       signed: bool) -> np.ndarray:
    required = (count * width + 7) // 8
    if len(data) != required:
        raise CodecError(f"packed field has {len(data)} bytes, expected {required}")
    mask = (1 << width) - 1
    sign = 1 << (width - 1)
    output = np.empty(count, dtype=np.int16)
    reservoir = 0
    available = 0
    cursor = 0
    for index in range(count):
        while available < width:
            reservoir |= data[cursor] << available
            cursor += 1
            available += 8
        value = reservoir & mask
        reservoir >>= width
        available -= width
        if signed and value & sign:
            value -= 1 << width
        output[index] = value
    if reservoir or any(data[cursor:]):
        raise CodecError("non-zero padding bits in packed field")
    return output


def pack_scale_codes(scale_codes: Sequence[int] | np.ndarray,
                     scale_format_id: int) -> bytes:
    values = np.asarray(scale_codes)
    if values.ndim != 1:
        raise CodecError("page scale slice must contain one scalar per token")
    if not np.issubdtype(values.dtype, np.integer):
        raise CodecError("scale codes must have an integer dtype")
    width = 12 if scale_format_id == SCALE_FORMAT_UQ4_8 else 16
    if scale_format_id not in (SCALE_FORMAT_UQ4_8, SCALE_FORMAT_UQ5_11):
        raise CodecError(f"unsupported scale format id {scale_format_id}")
    maximum = (1 << width) - 1
    if values.size and (int(values.min()) < 0 or int(values.max()) > maximum):
        raise CodecError(f"scale codes exceed unsigned {width}-bit range")
    return _pack_lsb_values(values.astype(np.uint16, copy=False), width)


def unpack_scale_codes(data: bytes, token_count: int,
                       scale_format_id: int) -> np.ndarray:
    width = 12 if scale_format_id == SCALE_FORMAT_UQ4_8 else 16
    if scale_format_id not in (SCALE_FORMAT_UQ4_8, SCALE_FORMAT_UQ5_11):
        raise CodecError(f"unsupported scale format id {scale_format_id}")
    return _unpack_lsb_values(data, token_count, width, signed=False).astype(
        np.uint16)


def pack_raw(codes: np.ndarray, bits: int) -> bytes:
    values = _require_codes(codes, bits)
    return _pack_lsb_values(values, bits)


def unpack_raw(payload: bytes, token_count: int, bits: int) -> np.ndarray:
    values = _unpack_lsb_values(
        payload, token_count * VECTOR_VALUES, bits, signed=True)
    minimum_reserved = -(1 << (bits - 1))
    if np.any(values == minimum_reserved):
        raise CodecError(f"reserved {bits}-bit minimum code encountered")
    return values.astype(np.int8).reshape(token_count, VECTOR_VALUES)


def _pack_prefix_bits(codes: np.ndarray, table: dict[str, str],
                      bits: int) -> bytes:
    values = _require_codes(codes, bits)
    output = bytearray()
    current = 0
    used = 0
    for value in values.reshape(-1):
        word = table[str(int(value))]
        for bit in word:
            current = (current << 1) | (bit == "1")
            used += 1
            if used == 8:
                output.append(current)
                current = 0
                used = 0
    if used:
        output.append(current << (8 - used))
    return bytes(output)


def _unpack_prefix_bits(payload: bytes, symbol_count: int,
                        table: dict[str, str], max_length: int) -> np.ndarray:
    inverse = {word: int(symbol) for symbol, word in table.items()}
    output = np.empty(symbol_count, dtype=np.int8)
    prefix = ""
    produced = 0
    bit_cursor = 0
    for byte in payload:
        for shift in range(7, -1, -1):
            bit_cursor += 1
            prefix += "1" if byte & (1 << shift) else "0"
            if prefix in inverse:
                output[produced] = inverse[prefix]
                produced += 1
                prefix = ""
                if produced == symbol_count:
                    total_bits = len(payload) * 8
                    remaining = total_bits - bit_cursor
                    if remaining >= 8:
                        raise CodecError("compressed payload has trailing bytes")
                    if remaining:
                        mask = (1 << remaining) - 1
                        if payload[-1] & mask:
                            raise CodecError("compressed payload has non-zero pad bits")
                    return output
            elif len(prefix) >= max_length:
                raise CodecError("invalid prefix code")
    raise CodecError(
        f"truncated prefix payload: decoded {produced}/{symbol_count} symbols")


def _stream_contract(is_v: bool, codebook: dict) -> tuple[str, int, dict, int]:
    stream = "V" if is_v else "K"
    bits = int(codebook[stream]["bits"])
    table = codebook[stream]["codes"]
    max_length = int(codebook[stream]["max_code_length"])
    return stream, bits, table, max_length


def _header_prefix(raw: bool, is_v: bool, token_count: int,
                   payload_bytes: int, codebook_id: int,
                   scale_format_id: int) -> bytes:
    if token_count < 1 or token_count > 256:
        raise CodecError("token_count must be in [1,256]")
    flags = (FLAG_RAW if raw else 0) | (FLAG_V if is_v else 0)
    return struct.pack(
        "<HBBHBB", MAGIC_VERSION, flags, token_count - 1,
        payload_bytes, codebook_id, scale_format_id)


def encode_page(codes: np.ndarray, scale_codes: Sequence[int] | np.ndarray,
                *, is_v: bool, scale_format_id: int = SCALE_FORMAT_UQ4_8,
                codebook: dict | None = None, crc_enable: bool = True,
                force_raw: bool = False) -> EncodedPage:
    codebook = codebook or load_codebook()
    _, bits, table, _ = _stream_contract(is_v, codebook)
    values = _require_codes(codes, bits)
    token_count = values.shape[0]
    if token_count < 1 or token_count > max(VALID_PAGE_TOKENS):
        raise CodecError("a page must hold between 1 and 128 tokens")
    scales = np.asarray(scale_codes)
    if scales.shape != (token_count,):
        raise CodecError("one scale code per page token is required")

    scale_slice = pack_scale_codes(scales, scale_format_id)
    raw_payload = pack_raw(values, bits)
    compressed_payload = _pack_prefix_bits(values, table, bits)
    raw = force_raw or len(compressed_payload) >= len(raw_payload)
    payload = raw_payload if raw else compressed_payload
    prefix = _header_prefix(
        raw, is_v, token_count, len(payload), CODEBOOK_STATIC_V1,
        scale_format_id)
    crc = crc32_iso_hdlc((prefix, payload, scale_slice)) if crc_enable else 0
    record = prefix + struct.pack("<I", crc) + payload
    header = PageHeader(
        raw=raw, is_v=is_v, token_count=token_count,
        payload_bytes=len(payload), codebook_id=CODEBOOK_STATIC_V1,
        scale_format_id=scale_format_id, crc32=crc)
    return EncodedPage(
        record=record, payload=payload, scale_slice=scale_slice,
        header=header, compressed_payload_bytes=len(compressed_payload),
        raw_payload_bytes=len(raw_payload))


def parse_header(record: bytes) -> PageHeader:
    if len(record) < HEADER_BYTES:
        raise CodecError("truncated page header")
    magic, flags, token_minus_one, payload_bytes, codebook_id, scale_format_id, crc = (
        HEADER.unpack_from(record, 0))
    if magic != MAGIC_VERSION:
        raise CodecError("bad magic/version")
    if flags & ~(FLAG_RAW | FLAG_V):
        raise CodecError("reserved header flag set")
    if codebook_id != CODEBOOK_STATIC_V1:
        raise CodecError("unsupported codebook id")
    if scale_format_id not in (SCALE_FORMAT_UQ4_8, SCALE_FORMAT_UQ5_11):
        raise CodecError("unsupported scale format id")
    if token_minus_one + 1 > max(VALID_PAGE_TOKENS):
        raise CodecError("page token count exceeds the v0.3 bound")
    return PageHeader(
        raw=bool(flags & FLAG_RAW), is_v=bool(flags & FLAG_V),
        token_count=token_minus_one + 1, payload_bytes=payload_bytes,
        codebook_id=codebook_id, scale_format_id=scale_format_id, crc32=crc)


def decode_page(record: bytes, scale_slice: bytes, *,
                codebook: dict | None = None, crc_enable: bool = True,
                expected_is_v: bool | None = None,
                expected_token_count: int | None = None,
                ) -> tuple[np.ndarray, np.ndarray, PageHeader]:
    codebook = codebook or load_codebook()
    header = parse_header(record)
    if expected_is_v is not None and header.is_v != expected_is_v:
        raise CodecError("K/V stream identity mismatch")
    if (expected_token_count is not None and
            header.token_count != expected_token_count):
        raise CodecError("page token count mismatch")
    end = HEADER_BYTES + header.payload_bytes
    if len(record) != end:
        raise CodecError(
            f"page record has {len(record)} bytes, header declares {end}")
    expected_scale_bytes = (
        header.token_count *
        (12 if header.scale_format_id == SCALE_FORMAT_UQ4_8 else 16) + 7) // 8
    if len(scale_slice) != expected_scale_bytes:
        raise CodecError("scale slice length mismatch")
    if crc_enable:
        actual_crc = crc32_iso_hdlc((record[:8], record[12:], scale_slice))
        if actual_crc != header.crc32:
            raise CRCError(
                f"page CRC mismatch: stored 0x{header.crc32:08x}, "
                f"actual 0x{actual_crc:08x}")
    elif header.crc32 != 0:
        raise CodecError("CRC-disabled page must store a zero CRC field")

    _, bits, table, max_length = _stream_contract(header.is_v, codebook)
    payload = record[HEADER_BYTES:end]
    if header.raw:
        codes = unpack_raw(payload, header.token_count, bits)
    else:
        codes = _unpack_prefix_bits(
            payload, header.token_count * VECTOR_VALUES, table, max_length
        ).reshape(header.token_count, VECTOR_VALUES)
    scales = unpack_scale_codes(
        scale_slice, header.token_count, header.scale_format_id)
    return codes, scales, header


def _align(value: int, alignment: int = ALIGNMENT_BYTES) -> int:
    return (value + alignment - 1) // alignment * alignment


def build_page_stream(codes: np.ndarray, scale_codes: Sequence[int] | np.ndarray,
                      *, page_tokens: int, is_v: bool,
                      scale_format_id: int = SCALE_FORMAT_UQ4_8,
                      codebook: dict | None = None,
                      crc_enable: bool = True) -> PageStream:
    if page_tokens not in VALID_PAGE_TOKENS:
        raise CodecError(f"page_tokens must be one of {VALID_PAGE_TOKENS}")
    codebook = codebook or load_codebook()
    _, bits, _, _ = _stream_contract(is_v, codebook)
    values = _require_codes(codes, bits)
    scales = np.asarray(scale_codes)
    if scales.shape != (values.shape[0],):
        raise CodecError("one scale code per token is required")

    data = bytearray()
    pages: list[EncodedPage] = []
    offsets: list[int] = []
    for start in range(0, values.shape[0], page_tokens):
        aligned = _align(len(data))
        data.extend(b"\x00" * (aligned - len(data)))
        offsets.append(aligned)
        stop = min(start + page_tokens, values.shape[0])
        page = encode_page(
            values[start:stop], scales[start:stop], is_v=is_v,
            scale_format_id=scale_format_id, codebook=codebook,
            crc_enable=crc_enable)
        pages.append(page)
        data.extend(page.record)
    offset_table = struct.pack(f"<{len(offsets)}I", *offsets) if offsets else b""
    return PageStream(
        data=bytes(data), offsets=tuple(offsets), offset_table=offset_table,
        offset_table_crc32=crc32_iso_hdlc((offset_table,)), pages=tuple(pages))


def verify_offset_table(offset_table: bytes, stored_crc32: int,
                        stream_bytes: int) -> tuple[int, ...]:
    if len(offset_table) % 4:
        raise CodecError("offset table length must be a multiple of four")
    actual = crc32_iso_hdlc((offset_table,))
    if actual != stored_crc32:
        raise CRCError(
            f"offset-table CRC mismatch: stored 0x{stored_crc32:08x}, "
            f"actual 0x{actual:08x}")
    count = len(offset_table) // 4
    offsets = struct.unpack(f"<{count}I", offset_table) if count else ()
    prior = -1
    for offset in offsets:
        if offset % ALIGNMENT_BYTES or offset <= prior or offset >= stream_bytes:
            raise CodecError("invalid or non-monotonic page offset")
        prior = offset
    return tuple(offsets)


def decode_page_stream(stream: PageStream, scale_plane: bytes, *,
                       page_tokens: int, is_v: bool,
                       scale_format_id: int = SCALE_FORMAT_UQ4_8,
                       codebook: dict | None = None,
                       crc_enable: bool = True,
                       total_tokens: int | None = None,
                       ) -> tuple[np.ndarray, np.ndarray]:
    codebook = codebook or load_codebook()
    offsets = verify_offset_table(
        stream.offset_table, stream.offset_table_crc32, len(stream.data))
    width = 12 if scale_format_id == SCALE_FORMAT_UQ4_8 else 16
    if total_tokens is None:
        total_tokens = sum(page.header.token_count for page in stream.pages)
    expected_scale_bytes = (total_tokens * width + 7) // 8
    if len(scale_plane) != expected_scale_bytes:
        raise CodecError("scale-plane size does not match token count")
    all_scale_codes = unpack_scale_codes(
        scale_plane, total_tokens, scale_format_id)
    decoded_codes: list[np.ndarray] = []
    decoded_scales: list[np.ndarray] = []
    token_cursor = 0
    for page_index, offset in enumerate(offsets):
        end = offsets[page_index + 1] if page_index + 1 < len(offsets) else len(stream.data)
        header = parse_header(stream.data[offset:end])
        record_end = offset + HEADER_BYTES + header.payload_bytes
        if any(stream.data[record_end:end]):
            raise CodecError("non-zero inter-page alignment padding")
        stop = token_cursor + header.token_count
        page_scales = pack_scale_codes(
            all_scale_codes[token_cursor:stop], scale_format_id)
        page_codes, page_scale_codes, _ = decode_page(
            stream.data[offset:record_end], page_scales, codebook=codebook,
            crc_enable=crc_enable, expected_is_v=is_v,
            expected_token_count=min(page_tokens, total_tokens - token_cursor))
        decoded_codes.append(page_codes)
        decoded_scales.append(page_scale_codes)
        token_cursor = stop
    if token_cursor != total_tokens:
        raise CodecError("page stream does not decode the declared token count")
    return np.concatenate(decoded_codes), np.concatenate(decoded_scales)


def stream_statistics(stream: PageStream, total_tokens: int, raw_bits: int,
                      scale_plane_bytes: int) -> dict[str, float | int]:
    raw_fallbacks = sum(page.header.raw for page in stream.pages)
    header_bytes = len(stream.pages) * HEADER_BYTES
    aligned_stream_bytes = len(stream.data)
    offset_bytes = len(stream.offset_table)
    global_crc_bytes = 4
    descriptor_bytes = 16
    full_bytes = (aligned_stream_bytes + scale_plane_bytes + offset_bytes +
                  global_crc_bytes + descriptor_bytes)
    return {
        "tokens": total_tokens,
        "pages": len(stream.pages),
        "raw_fallback_pages": raw_fallbacks,
        "raw_fallback_fraction": raw_fallbacks / max(1, len(stream.pages)),
        "payload_bytes": sum(page.header.payload_bytes for page in stream.pages),
        "page_header_bytes": header_bytes,
        "alignment_padding_bytes": aligned_stream_bytes - header_bytes - sum(
            page.header.payload_bytes for page in stream.pages),
        "offset_table_bytes": offset_bytes,
        "offset_table_crc_bytes": global_crc_bytes,
        "stream_descriptor_bytes": descriptor_bytes,
        "scale_plane_bytes": scale_plane_bytes,
        "full_bytes": full_bytes,
        "full_bytes_per_token": full_bytes / total_tokens,
        "effective_bits_per_value": full_bytes * 8 / (total_tokens * VECTOR_VALUES),
        "raw_payload_bytes": total_tokens * VECTOR_VALUES * raw_bits // 8,
    }


def _cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if not args.self_test:
        parser.error("select --self-test")
    if crc32_iso_hdlc((b"123456789",)) != 0xCBF43926:
        raise AssertionError("CRC-32/ISO-HDLC check value failed")
    rng = np.random.default_rng(20260816)
    for page_tokens in VALID_PAGE_TOKENS:
        for is_v, bits in ((False, 4), (True, 5)):
            qmax = (1 << (bits - 1)) - 1
            codes = rng.integers(-qmax, qmax + 1,
                                 size=(page_tokens + 7, VECTOR_VALUES),
                                 dtype=np.int16).astype(np.int8)
            scales = rng.integers(1, 4096, size=page_tokens + 7,
                                  dtype=np.uint16)
            stream = build_page_stream(
                codes, scales, page_tokens=page_tokens, is_v=is_v)
            scale_plane = pack_scale_codes(scales, SCALE_FORMAT_UQ4_8)
            actual_codes, actual_scales = decode_page_stream(
                stream, scale_plane, page_tokens=page_tokens, is_v=is_v,
                total_tokens=len(scales))
            np.testing.assert_array_equal(actual_codes, codes)
            np.testing.assert_array_equal(actual_scales, scales)
    print("PACKED5 page codec self-test PASS")


if __name__ == "__main__":
    _cli()
