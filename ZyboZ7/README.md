# Zybo Z7-20 temporary bring-up platform

This directory contains a deliberately small Vivado 2025.1 platform for the
first Zybo Z7-20 hardware gates. It is **bring-up infrastructure only**. It is
not the final KVQ topology and is not evidence that the KVQ page scheduler,
codec, or arithmetic path is integrated.

The design proves the interfaces that the later accelerator will depend on:

- the pinned Digilent processing-system preset supplies PS DDR, FIXED_IO, and
  PS UART1 on MIO 48/49;
- PS `M_AXI_GP0` reaches a 64 KiB AXI BRAM window and AXI CDMA registers;
- a 64-bit AXI CDMA master reaches PS DDR through `S_AXI_HP0`;
- when explicitly enabled, the separate raw-V5/AV diagnostic IP receives a
  64 KiB GP0 control window and a native 64-bit HP0 read path;
- alternatively, RAW-full mode replaces both optional KV/AV diagnostics with
  one K4/QK/softmax/V5/AV IP and two independent 64- or 128-bit read masters;
- alternatively, canned-page mode replaces every other optional diagnostic
  with a host-loaded CRC/page128 decoder and KVQ arithmetic IP; it has no
  external HP0 master and retains the baseline BRAM/CDMA path;
- all PL AXI logic uses one explicit MMCM output and one synchronized reset
  domain.

The CDMA is a temporary transport exerciser. It copies DDR-to-DDR through HP0;
it does not represent the final KVQ read/write master.

## Fixed target and address map

| Item | Value |
|---|---|
| Vivado release | 2025.1, exact full build recorded at create time |
| Board part | `digilentinc.com:zybo-z7-20:part0:1.2` |
| Device | `xc7z020clg400-1` |
| PS UART | UART1, MIO 48/49, 115200 baud preset |
| AXI BRAM | `0x43C00000`, 64 KiB; propagated `16384 x 32` configuration |
| AXI CDMA registers | `0x43C10000`, 64 KiB |
| ABI-v2 KV control (optional) | `0x43C20000`, 64 KiB |
| Raw-V5/AV diagnostic control (optional) | `0x43C30000`, 64 KiB |
| RAW-full diagnostic control (exclusive optional mode) | `0x43C20000`, 64 KiB |
| Canned-page diagnostic control (exclusive optional mode) | `0x43C20000`, 64 KiB |
| HP port | `S_AXI_HP0`, 64-bit |
| First PL clock | 75.000 MHz: 100 MHz x 9 / 12 |
| Target PL clock | 81.250 MHz: 100 MHz x 8.125 / 10 |

The clock source is repository RTL in `rtl/zybo_pl_clock.v`, not Clocking
Wizard output. Its module-reference wrappers carry fixed clock metadata for
75 MHz and 81.25 MHz. The MMCM has no fabric input buffer and no independent
`create_clock`; Vivado must derive its output generated clock from the PS
`clk_fpga_0` clock. The build rejects every DRC or methodology Error/Critical
Warning, including the TIMING-2/TIMING-4 duplicate-primary-clock failure that
invalidated the earlier Clocking-Wizard experiment.

The pinned Digilent board file identifies compatible PCB revision B.2. The
physical board is the user-confirmed Zybo Z7-20 PCB revision D. This bring-up uses
only the common PS DDR, FIXED_IO, and UART wiring; it does not exercise
revision-sensitive Ethernet or QSPI behavior. Do not program a bitstream until
the exact build identity and selected JTAG cable serial have been verified.

## Required environment

Run the wrappers with PowerShell 7 or newer (`pwsh.exe`). They fail before
creating output under Windows PowerShell 5.1 because safe relative-path and
whole-process-tree operations require the newer runtime.

`TERNARYCORE_BOARD_FILES` must name the directory that directly contains the
Digilent board directories. For the prepared workstation:

```powershell
$env:TERNARYCORE_BOARD_FILES = 'D:\tc-tools\board-files\digilent-vivado-boards\new\board_files'
```

The raw-V5/AV numerator diagnostic remains disabled unless
`TERNARYCORE_AV_DIAG_IP_REPO` names a packaged-IP repository containing the
exact file `axi_v5_av_diag\component.xml`:

```powershell
$env:TERNARYCORE_AV_DIAG_IP_REPO = 'D:\tc-work\ternarycore\ip-repo-<unique-id>'
```

When enabled, the platform instantiates
`shepherdscientific.com:user:axi_v5_av_diag:1.0` as `axi_v5_av_diag_0`, connects
GP0 interconnect master `M03` to its control slave, and connects its AXI read
master to HP0 SmartConnect input `S02`. The first board configuration fixes the
diagnostic master's internal data width at 64 bits regardless of the separately
selected ABI-v2 KV transport. Its DDR aperture is `0x00000000`, 1 GiB. This
diagnostic is not the page scheduler, CRC/integrity path, or final normalized AV
output.

This is an additive diagnostic build: `TERNARYCORE_KV_IP_REPO` must also be set
so the existing ABI-v2 KV IP remains on GP0 `M02` and HP0 `S01`. With only the
AV environment variable set, creation fails before a project is written rather
than leaving reserved interconnect slots unconnected.

RAW-full mode is a separate, replacement configuration. Set
`TERNARYCORE_RAW_FULL_IP_REPO` to a packaged repository containing the exact
file `axi_kvq_raw_full_diag\component.xml`. Do not set the old KV transport or
AV diagnostic variables in this mode; creation fails closed if they coexist.

```powershell
$env:TERNARYCORE_RAW_FULL_IP_REPO = 'D:\tc-work\ternarycore\raw-full-ip-<unique-id>\ip'

& 'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\Build-ZyboPlatform.ps1' `
    -OutputDirectory $output `
    -EvidenceDirectory $evidence `
    -ClockMHz 75 `
    -RawFullAxiWidth 64 `
    -RawFullScaleWidth 12 `
    -RawFullProfile BALANCED `
    -Jobs 4
```

`-RawFullAxiWidth` accepts exactly `64` or `128`, and
`-RawFullScaleWidth` accepts exactly `12` or `16`. The two accepted resource
profiles are `BALANCED` (`QK_MULT_STYLE=2`, `AV_MULT_STYLE=2`) and
`LUT_RELIEF` (`QK_MULT_STYLE=2`, `AV_MULT_STYLE=1`). Both K and V AXI masters
use the selected width and connect separately to HP0 SmartConnect inputs `S01`
and `S02`; CDMA remains on `S00`. HP0 and SmartConnect `M00` stay 64-bit, so
SmartConnect performs the width conversion for a 128-bit RAW-full selection.
The baseline BRAM and CDMA blocks remain
present. The identity records the normalized IP repository, exact
`component.xml` SHA-256, data/scale widths, both multiplier styles, and the
derived profile. No RAW-full setting is accepted without the RAW-full IP repo.

Package the raw-full core into a brand-new external `D:` output with:

```powershell
& 'D:\xilinx\2025.1\Vivado\bin\vivado.bat' -mode batch `
    -log D:\tc-logs\raw-full-package.log `
    -journal D:\tc-logs\raw-full-package.jou `
    -source D:\Xilinx_LLM\wt-kv-v03\ip\package_axi_kvq_raw_full_diag_portable.tcl `
    -tclargs D:\Xilinx_LLM\wt-kv-v03 D:\tc-work\raw-full-pkg-<unique-id> `
        xc7z020clg400-1 76923080 64 12 2 2
```

The final four values are AXI width, scale width, QK multiplier style, and AV
multiplier style. Use `128 16 2 1` for the AXI128, scale-16 LUT-relief variant. The
packager preserves immutable source snapshots and provenance beside the IP.

Canned-page mode is a second exclusive replacement configuration. Set
`TERNARYCORE_CANNED_PAGE_IP_REPO` to a packaged repository containing
`axi_kvq_canned_page_diag\component.xml`; do not set KV, AV, or RAW-full mode
variables at the same time. The IP is AXI-Lite only, is mapped at
`0x43C20000`, and does not consume another HP0 SmartConnect input.

```powershell
$env:TERNARYCORE_CANNED_PAGE_IP_REPO = `
    'D:\tc-work\canned-page-pkg-<unique-id>\ip'

& 'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\Build-ZyboPlatform.ps1' `
    -OutputDirectory $output `
    -EvidenceDirectory $evidence `
    -ClockMHz 75 `
    -CannedPageScaleBits 12 `
    -CannedPageDecodeLanes 2 `
    -CannedPageProfile BALANCED `
    -Jobs 4
```

The scale is exactly `12` or `16`. The decode-lane count is a compile-time
choice of `2` (production candidate) or `4` (retained reference); it is not a
runtime mux. `BALANCED` records QK/AV styles `2/2`; `LUT_RELIEF` records
`2/1`. Both the platform identity and build result also pin the lane count,
compiled profile ID `51`, K codebook ID `1`, V codebook ID `2`, and the
packaged `component.xml` SHA-256.

Package this IP into a brand-new external `D:` output before enabling the
mode:

```powershell
& 'D:\xilinx\2025.1\Vivado\bin\vivado.bat' -mode batch `
    -log D:\tc-logs\canned-page-package.log `
    -journal D:\tc-logs\canned-page-package.jou `
    -source D:\Xilinx_LLM\wt-kv-v03\ip\package_axi_kvq_canned_page_diag_portable.tcl `
    -tclargs D:\Xilinx_LLM\wt-kv-v03 `
        D:\tc-work\canned-page-pkg-<unique-id> `
        xc7z020clg400-1 75000000 12 2 2 2
```

The last four values are `SCALE_BITS`, `DECODE_LANES`, QK style, and AV
style. The accepted lane count is `2` or `4`; QK style is `2`, and AV style
is `2` or `1`. All other tuples fail closed.

The scripts require Git so they can enumerate every worktree and require the
clean Digilent board-repository commit
`36f34ab687b7fa9c778b779d027f3bce63b3ace9`. GitHub Desktop's newest bundled
Git is discovered when Git is not already on `PATH`; its `cmd` directory is
prepended to the child Vivado process `PATH` so the Tcl identity checks can use
bare `git`. On Windows, output is restricted to `D:` to protect the small
system drive. The scripts do not fall back to a user profile, Vivado install
directory, or `HOME`.

## Mandatory Icarus clock gate

Every change to `rtl/zybo_pl_clock.v` must pass this test before Vivado is
opened:

```powershell
$root = 'D:\Xilinx_LLM\wt-kv-v03'
$sim = 'D:\tc-work\ternarycore\zybo-clock-test.vvp'

& 'D:\tc-tools\iverilog\12.0\bin\iverilog.exe' -g2012 -Wall `
    -s tb_zybo_pl_clock -o $sim `
    "$root\ZyboZ7\tb\zybo_clock_primitive_stubs.v" `
    "$root\ZyboZ7\rtl\zybo_pl_clock.v" `
    "$root\ZyboZ7\tb\tb_zybo_pl_clock.v"
if ($LASTEXITCODE -ne 0) { throw 'Icarus compile failed' }

& 'D:\tc-tools\iverilog\12.0\bin\vvp.exe' $sim
if ($LASTEXITCODE -ne 0) { throw 'Icarus clock test failed' }
```

The required final marker is `ZYBO_PL_CLOCK_IVERILOG_PASS`.

## Required one-shot create/build wrapper

Run `Build-ZyboPlatform.ps1`; do not invoke the create/build Tcl files directly
for an accepted hardware artifact. Vivado 2025.1 does not provide a usable
`get_messages` command here, so the wrapper makes the retained message streams
part of the pass/fail contract.

Both supplied paths must be brand-new, disjoint, on `D:`, outside every Git
worktree, outside the pinned Digilent board repository, and have existing
parent directories. Neither path may be an ancestor of those protected roots.
Create and build are one-shot: if either fails, retain both directories and
choose new paths for the next attempt. The wrapper never deletes or silently
reuses generated state.

```powershell
$source = 'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7'
$output = 'D:\tc-work\ternarycore\zybo-bringup-75-<unique-id>'
$evidence = 'D:\tc-logs\ternarycore\zybo-bringup\75-<same-unique-id>'

& "$source\Build-ZyboPlatform.ps1" `
    -OutputDirectory $output `
    -EvidenceDirectory $evidence `
    -ClockMHz 75 `
    -Jobs 4 `
    -TimeoutSeconds 7200
if ($LASTEXITCODE -ne 0) { throw 'Zybo platform wrapper failed' }
```

For 81.25 MHz, use new output/evidence paths and pass `-ClockMHz 81.25`.
Never retarget a 75 MHz project in place.

Each Vivado stage runs from the external evidence directory with `TMP`, `TEMP`,
and `TMPDIR` redirected there. It has an explicit timeout; timeout cleanup uses
the exact spawned process ID and its descendant process tree. The evidence set
contains separate create/build Vivado logs, journals, standard-output logs, and
standard-error logs.

The wrapper requires exactly one `ZYBO_PLATFORM_CREATE_PASS` and one
`ZYBO_PLATFORM_BUILD_PASS`, a zero exit code for each process, all completion
markers, reports, and exactly one nonempty bitstream and XSA. It scans the
explicit evidence streams and generated Vivado run logs. Every Critical
Warning fails except these exact Digilent PS7-preset tuples:

| ID | Parameter/index | Exact value |
| --- | --- | --- |
| `PSU-1` | `PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0` / `0` | `-0.050` |
| `PSU-2` | `PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1` / `1` | `-0.044` |
| `PSU-3` | `PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2` / `2` | `-0.035` |
| `PSU-4` | `PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3` / `3` | `-0.100` |

The exact message must also be `PS DDR interfaces might fail when entering
negative DQS skew values.` An ID with any other parameter, suffix index, value,
or message fails. Every allowlisted occurrence, parsed tuple, source-log hash,
line text, line number, and line hash is recorded in `RUN_IDENTITY.json`.
`ERROR:` and `FATAL:` messages also fail even if the vendor launcher returns
zero.

Creation writes `identity/manifest.tcl`, a readable `identity/identity.txt`,
and byte-for-byte source snapshots with SHA-256 digests. The identity records
the full Vivado build, Git commit/dirty flag, all worktrees, Digilent repository
commit, part, board part, selected clock wrapper, and clock frequency. Build
refuses source, tool, path, or board-repository drift and creates a one-shot
`.build_started` marker before touching runs.

If the AV diagnostic is enabled, the identity and build result additionally
record `av_diag_enabled`, the normalized IP repository, the packaged
`component.xml` SHA-256, and `av_m_axi_data_width=64`. Create fails when the
component is absent. Build rehashes it before opening runs, and the PowerShell
wrapper records its file identity in `RUN_INPUTS.json` and rejects a hash change
during the complete create/build run.

If RAW-full mode is enabled, the same create/build/launcher hash checks apply
to its component. The block-design assertions also require the exclusive cell,
its exact two-master HP0 topology, the `0x43C20000` control map, and the exact
scale/profile parameter tuple before synthesis can start.

Successful build output contains:

- `reports/timing_summary.rpt`, utilization, clock, DRC, methodology, and a
  detailed CDC report generated with waivers ignored;
- `artifacts/zybo_bringup_<frequency>MHz.bit`;
- `artifacts/zybo_bringup_<frequency>MHz.xsa`, fixed and bitstream-bearing;
- `artifacts/SHA256SUMS.txt` and `artifacts/build_result.tcl`;
- `.build_complete` only after timing, report-severity, source-identity, XSA,
  and bitstream gates pass.

The timing gate parses the 12-column `Design Timing Summary` row rather than
using run `STATS.WPWS`, which is not available in Vivado 2025.1. WNS, TNS, WHS,
THS, WPWS, and TPWS must all be numeric and nonnegative, and setup, hold, and
pulse-width failing-endpoint counts must all be zero. The existing twelve
`check_timing` categories must each be present with zero violations. The CDC
report is generated with waivers ignored and fails closed on Critical, unsafe,
unknown, malformed, or uncontracted summary evidence. Creation also asserts,
after block-design propagation, that `bram_0` has `Write_Depth_A=16384`,
`Write_Width_A=32`, and `Read_Width_A=32`.

A `.bit` file left by an incomplete attempt is not approved for programming.
Only artifacts accompanied by `.build_complete`, a `PASS` result in the
external `RUN_IDENTITY.json`, and the exact `ZYBO_PLATFORM_LAUNCH_PASS` wrapper
token are candidates for the physical-board gate.

## RAW-full XSDB smoke

Before connecting hardware, run the canned c7 oracle for both scale formats:

```powershell
& 'D:\xilinx\2025.1\Vitis\bin\xsdb.bat' `
    'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\run_kvq_raw_full_board_smoke.tcl' `
    --self-test
```

Its final static marker is `KVQ_RAW_FULL_STATIC_ORACLE_PASS`. The hardware
form requires the exact expected Digilent cable serial; it will not select a
board by a positional target number:

```powershell
& 'D:\xilinx\2025.1\Vitis\bin\xsdb.bat' `
    'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\run_kvq_raw_full_board_smoke.tcl' `
    $output $evidence '<exact-cable-serial>'
```

Before sourcing generated `ps7_init.tcl` or connecting to a target, the script
requires the wrapper PASS, rehashes the bitstream, XSA, PS initialization,
build identity/result and packaged component, checks every repository RAW-full
RTL source against the package identity, and checks the selected AXI width,
scale width, and resource profile.
The c7 board sequence loads independent Q/K/V and K/V scales, compares all 28
committed Q8.8 scores, four denominators and F12 reciprocals, and every one of
the 512 signed-48 numerators and signed-18 normalized results against its Tcl
oracle. It records both master counter sets, verifies that score/result windows
are hidden before `RESULT_VALID`, after `CLEAR`, abort, and a typed K4 fault,
then performs a no-reset restart. No physical execution has yet been claimed;
the required final hardware marker is `KVQ_RAW_FULL_BOARD_SMOKE_PASS`.

## Canned RAW/COMPRESSED page XSDB smoke

Run both scale-format image/CRC self-tests without connecting hardware:

```powershell
& 'D:\xilinx\2025.1\Vitis\bin\xsdb.bat' `
    'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\run_kvq_canned_page_board_smoke.tcl' `
    --self-test
```

The final offline marker is `KVQ_CANNED_PAGE_STATIC_ORACLE_PASS`. After a
completed canned-page platform build, run the physical A/B test with the exact
Digilent cable serial:

```powershell
& 'D:\xilinx\2025.1\Vitis\bin\xsdb.bat' `
    'D:\Xilinx_LLM\wt-kv-v03\ZyboZ7\run_kvq_canned_page_board_smoke.tcl' `
    $output $evidence '210351B7BAE7A'
```

The script verifies the wrapper, build, package, component, source, bitstream,
XSA, and PS-init hashes before connecting. It runs full context-128 RAW and
COMPRESSED K/V pages, compares all 512 scores, 512 signed-48 numerators, 512
normalized results, and all four denominator/reciprocal values, records page,
decoder, starvation, and arithmetic counters, then checks profile, codebook,
CRC, decoder, abort/drain, hidden-result, and no-reset restart behavior. The
required hardware marker is `KVQ_CANNED_PAGE_BOARD_SMOKE_PASS`.

## First software proof

Use the repository bare-metal Vitis application generated from the XSA:

1. print a PS UART1 hello message;
2. test PS DDR independently;
3. write/read randomized words through the AXI BRAM window;
4. prepare aligned source and destination DDR buffers;
5. flush source and destination cache ranges and issue a barrier;
6. run an aligned CDMA copy through HP0;
7. invalidate the destination range and issue a barrier before comparison;
8. repeat with randomized lengths and 4 KiB boundary crossings.

The CDMA data realignment engine is disabled. Source, destination, and length
must satisfy the 64-bit alignment requirements. Cache ownership is part of the
test contract; stale cached data is not an RTL failure.
