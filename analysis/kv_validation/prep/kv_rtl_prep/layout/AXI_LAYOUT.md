# KV AXI Memory Layout Contract v0.1

Baseline geometry:
- head_dim = 128
- K/V payload = symmetric INT4, 64 bytes/vector
- scale = unsigned 16-bit metadata, 2 bytes/vector
- K and V use identical storage rules

## Preferred layout: split planes

Payload plane:
- contiguous packed INT4 vectors
- vector i starts at `payload_base + i * 64`
- low nibble stores the lower-index element; high nibble stores the next element
- mathematical codebook is -7..+7
- nibble 0x8 is reserved/invalid for canonical data
- 0x9..0xF encode -7..-1 in ordinary 4-bit two's-complement form

Scale plane:
- contiguous little-endian uint16 scale codes
- vector i scale starts at `scale_base + i * 2`
- binary-point interpretation is intentionally NOT frozen until real-model scale statistics are available

Why split planes:
- 64-byte INT4 payload aligns exactly to 4 beats on AXI-128 and 2 beats on AXI-256
- scale metadata can be streamed/ prefetched independently
- avoids turning a 66-byte logical record into 80 bytes on AXI-128 or 96 bytes on AXI-256 if every record is independently beat-aligned
- preserves predictable burst addressing

## Addressing

K payload:
`K_payload_addr(token, kv_head) = K_payload_base + ((token * N_KV_HEADS + kv_head) * 64)`

V payload:
`V_payload_addr(token, kv_head) = V_payload_base + ((token * N_KV_HEADS + kv_head) * 64)`

K scale:
`K_scale_addr(token, kv_head) = K_scale_base + ((token * N_KV_HEADS + kv_head) * 2)`

V scale:
`V_scale_addr(token, kv_head) = V_scale_base + ((token * N_KV_HEADS + kv_head) * 2)`

No assumption is made yet about page size, 4 KiB crossing policy, or DDR controller burst limits.
Those belong to the integration contract rather than the numeric format.
