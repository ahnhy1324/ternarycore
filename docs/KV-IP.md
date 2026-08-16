# INT4 KV-cache IP v0.1

The first hardware milestone is a read-only K path:

`DDR K vector -> signed INT4 unpack -> Q8.8 dequant -> INT8 Q dot -> logits`

It is intentionally independent of V accumulation, softmax, write-side
quantization, Hadamard transforms, and deterministic dither.

## Geometry and numeric contract

| Item | v0.1 value |
|---|---:|
| `HEAD_DIM` | 64 |
| `KV_BITS` | 4, signed two's complement |
| `P` | 16 lanes |
| `MAX_CONTEXT` | 4096 |
| Query | signed INT8 |
| K scale | signed Q8.8, one scale per run |
| Logit | signed 32-bit, binary point remains at bit 8 |
| Arty memory port | 128-bit AXI4, two beats per K vector |
| Portable handoff port | 256-bit AXI4, one beat per K vector |

Nibbles are LSB-first: byte bits `[3:0]` are the lower dimension and bits
`[7:4]` are the next dimension. One 64-element vector is 32 bytes. `K_BASE`
is the already-computed base for one layer/KV-head and must be 32-byte aligned:

`K_ADDR(token) = K_BASE + token * 32`

The executable reference is `sim/verify/verify_kv_int4.py`.

## Register map

The Arty DDR block design maps the 64-KiB AXI-Lite aperture at `0x44500000`.

| Offset | Register | Meaning |
|---:|---|---|
| `0x0000` | `CTRL` | write bit 0 start; bit 1 clear status; read bit 31 done |
| `0x0004` | `STATUS` | bit 0 busy, bit 1 done, bit 2 error |
| `0x0008` | `K_BASE_LO` | lower K-region address |
| `0x000C` | `K_BASE_HI` | upper K-region address |
| `0x001C` | `CONTEXT_LEN` | runtime number of K vectors, 1..4096 |
| `0x0020` | `TOKEN_POS` | reserved metadata for later dither/control |
| `0x0024` | `CFG` | signed Q8.8 K scale in bits `[15:0]` |
| `0x0028` | `PERF_CYCLES` | cycles in the most recent/current run |
| `0x002C` | `ERROR` | error code in bits `[7:0]` |
| `0x0030` | `ID` | `0x4B560001` |
| `0x0034` | `GEOMETRY` | AXI width, head dim, lanes, KV bits |
| `0x0100..013F` | `Q` | 64 INT8 values, four per 32-bit word |
| `0x1000..4FFF` | `LOGITS` | 4096 signed 32-bit results |

Error `0x01` is an invalid context, `0x02` is an unaligned base, `0x11/0x12`
are AXI timeouts, `0x13` is an AXI error response, `0x14` is malformed RLAST,
and `0x80` is a start request while busy.

## Existing firmware incompatibility

`firmware/ddr_host.c` currently uses an INT8, bit-sliced cache with
`HEAD_DIM=128` so that the existing ternary array can execute attention. That
layout is not the row-major INT4 ABI above. Do not point this IP at the current
`KV_K` region. Integration needs a new INT4 producer/converter and a reserved
DDR region before firmware enables the block.

## Reproducible checks

From `sim/`:

```sh
make tb_kv_cache
make verify
```

The RTL regression runs lengths `1,7,63,64,65,511,512,513,4095,4096` in both
128- and 256-bit AXI configurations, with randomized AXI address/data stalls,
a short run after 4096, invalid arguments, and AXI error propagation.

Package and build after simulation passes:

```sh
vivado -mode batch -source ip/package_axi_kv_cache.tcl
./Arty7/build_ddr.sh
```

The packaging script generates the version-specific `ip/axi_kv_cache`
metadata locally. Keeping that generated churn out of the RTL branch allows
the same sources to be packaged later with Vivado 2025.2.
