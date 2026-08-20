# Windows Vivado 2025.1 environment

This directory defines the reproducible Windows tool environment for the
Zybo Z7-20 migration. The lock file records the installed D-drive layout and
the exact Digilent board-files commit. No script changes User or Machine
`PATH`, stores a license value, or copies files into the Vivado installation.

## Start a PowerShell session

Use PowerShell 7 or newer (`pwsh.exe`). From the repository root, dot-source the environment script so its changes
remain in the current PowerShell process only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
. .\tools\windows\Enter-TernaryCoreEnvironment.ps1
```

The session receives explicit Vivado, Vitis, Cortex-A9 GCC, Icarus, Verilator,
GNU make, Python,
Git, board-file, work, and evidence paths. The canonical board-file variable
used by the Zybo scripts is `TERNARYCORE_BOARD_FILES`. Git is resolved from an
existing absolute `TERNARYCORE_GIT_EXECUTABLE`, the current process `PATH`, or
the newest installed GitHub Desktop bundle, in that order. The resolved path
is exported as `TERNARYCORE_GIT_EXECUTABLE`, and only its `cmd` directory is
prepended to the current process `PATH`. No User or Machine `PATH` is changed.
Scratch and evidence default to:

```text
D:\tc-work\ternarycore
D:\tc-logs\ternarycore
```

Closing that PowerShell session discards the PATH changes.

## Run the environment gate

The full gate checks pinned files and hashes, the detached board-files commit,
tool versions, small Icarus/Verilator/ARM/Python/XSCT smokes, and a read-only Vivado board
query:

```powershell
.\tools\windows\Test-TernaryCoreEnvironment.ps1
```

Vivado runs with a D-drive working directory. Its Tcl check sets
`board.repoPaths` for that process only and requires:

```text
digilentinc.com:zybo-z7-20:part0:1.2
xc7z020clg400-1
```

For lock, path, Git, and hash checks without launching any FPGA tool:

```powershell
.\tools\windows\Test-TernaryCoreEnvironment.ps1 -StaticOnly
```

Use `-SkipVivado` to run all other tool smokes, or `-KeepWork` to retain a
successful smoke-test directory. The gate writes a curated `ENVIRONMENT.json`
and log under `D:\tc-logs\ternarycore\environment-gate`; it never dumps the
process environment or license variables.

## Run RTL verification

After entering the environment:

```powershell
.\sim\run_windows_regression.ps1
```

Useful variants are:

```powershell
.\sim\run_windows_regression.ps1 -KvOnly -SkipPython
.\sim\run_windows_regression.ps1 -KeepWork
.\sim\run_windows_regression.ps1 `
  -WorkRoot D:\tc-work\ternarycore `
  -EvidenceRoot D:\tc-logs\ternarycore
```

Successful scratch directories are removed unless `-KeepWork` is supplied.
Failed runs always retain scratch and record its exact location. Evidence logs
are separate and retained. Work and evidence roots must be disjoint; neither
may contain the other. The full run includes the legacy streaming, INT8,
RMSNorm, widened-MAC, 128-bit BRAM, and exact Zybo MMCM clock benches as well
as the core and KV suites. Every simulation and Python check must emit its own positive completion
marker before the runner records it as passed.

## Board revision boundary

The pinned definition is the official Zybo Z7-20 board part, but its XML is
stored under `A.0` and lists compatible PCB revision `B.2`. It does not prove
the physical board revision. The user's earlier `D` likely identified the
installation drive, not the PCB. PCB revision, DDR size,
JTAG IDCODE, power, and attached peripherals remain separate board-ID evidence.
