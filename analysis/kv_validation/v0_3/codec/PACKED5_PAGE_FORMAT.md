# PACKED5 page format — theory-closed v0.3

This file records the executable software/RTL contract. It supersedes
`source_v03/codec/PACKED5_PAGE64_FORMAT.md` where the original document says
`CRC32(payload)`.

## Streams and task identity

K payload, V payload, K scale, and V scale are separate planes. A page decoder
task is identified by `(stream, layer, KV head, page)`. Parallel decoder engines
operate on independent tasks; a page is not split into byte-aligned substreams.

Page sizes are 64 or 128 tokens. The preferred baseline is page128 with a 2×2
decoder organization; page64 is retained as the lower-latency comparison.

## Header

Every page starts at a 16-byte-aligned offset. Its 12-byte little-endian header
uses Python/RTL layout `<HBBHBBI>`:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 2 | magic/version `0xC303` |
| 2 | 1 | flags: bit 0 raw fallback, bit 1 V stream; others zero |
| 3 | 1 | token count minus one |
| 4 | 2 | payload byte count |
| 6 | 1 | static codebook ID (`1`) |
| 7 | 1 | scale format ID (`1` = UQ4.8/12-bit, `2` = UQ5.11/16-bit) |
| 8 | 4 | CRC-32/ISO-HDLC |

The CRC is computed over:

```text
header bytes [0:8] || payload || corresponding scale slice
```

CRC parameters are normal polynomial `0x04C11DB7`, reflected polynomial
`0xEDB88320`, init/xorout `0xFFFFFFFF`, refin/refout true, and check value
`0xCBF43926` for `123456789`. The CRC field itself is excluded.

Each K and V offset table is a packed little-endian sequence of 32-bit page
offsets. Its descriptor carries a separate CRC-32/ISO-HDLC over the complete
offset-table bytes. Full accounting reserves 16 descriptor bytes per stream in
addition to the four-byte table CRC.

## Payload coding

- K has 128 signed narrow-range INT4 symbols per token (`-7..7`); `-8` is
  reserved and invalid.
- V has 128 signed narrow-range INT5 symbols per token (`-15..15`); `-16` is
  reserved and invalid.
- Compressed pages use the checked-in static prefix codebook. Code-string bits
  are serialized in order, MSB first within a byte. Only the final byte may
  contain zero padding.
- Exactly `token_count × 128` symbols must decode. Invalid prefixes, truncation,
  trailing bytes, and nonzero padding are errors.
- A page falls back to raw only when the compressed payload is not smaller.
- Raw signed symbols use a contiguous LSB-first bit reservoir with no per-token
  byte padding.

## Scale plane

UQ4.8 stores one unsigned 12-bit scale per token/KV head. Values are packed in
a contiguous LSB-first reservoir. Because both nominal page sizes are even,
page scale slices begin on byte boundaries. UQ5.11 uses one little-reservoir
16-bit value per token/KV head.

Code selection always uses the high-precision absmax scale. Only
dequantization uses the rounded stored scale.

## Fault behavior

Any header, payload, scale-slice, offset, truncation, or invalid-prefix failure
must set a sticky typed error, suppress decoder output, abort the affected row
or request reload, and prevent partially decoded state from becoming visible.
A failed compressed page is never reinterpreted as raw.

The bit-exact reference is
`../../scripts/packed5_page_codec.py`; generated pages and fault reports are in
this directory.
