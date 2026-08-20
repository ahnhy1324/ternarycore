[CmdletBinding()]
param(
    [string]$LockFile = (Join-Path $PSScriptRoot "toolchain-2025.1.lock.json"),
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be an absolute path: $Path"
    }
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,
        [Parameter(Mandatory = $true)]
        [string]$Child,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd("\")
    $childFull = [IO.Path]::GetFullPath($Child)
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    if (-not $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside its allowed root: $childFull"
    }
}

function Resolve-LockedAbsolutePath {
    param([string]$Path, [string]$Label)

    Assert-AbsolutePath -Path $Path -Label $Label
    [IO.Path]::GetFullPath($Path)
}

function Resolve-LockedChildPath {
    param([string]$Parent, [string]$Path, [string]$Label)

    if ([IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be relative to its locked root: $Path"
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Parent $Path))
    Assert-ChildPath -Parent $Parent -Child $resolved -Label $Label
    $resolved
}

function Assert-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label directory not found: $Path"
    }
}

function Assert-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label file not found: $Path"
    }
}

function Resolve-TernaryCoreGitExecutable {
    $explicit = [Environment]::GetEnvironmentVariable(
        "TERNARYCORE_GIT_EXECUTABLE", "Process")
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        Assert-AbsolutePath -Path $explicit -Label "TERNARYCORE_GIT_EXECUTABLE"
        $resolved = [IO.Path]::GetFullPath($explicit)
        Assert-File -Path $resolved -Label "TERNARYCORE_GIT_EXECUTABLE"
        return $resolved
    }

    $pathGit = Get-Command git.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathGit -and
        -not [string]::IsNullOrWhiteSpace([string]$pathGit.Source)) {
        $resolved = [IO.Path]::GetFullPath([string]$pathGit.Source)
        Assert-File -Path $resolved -Label "Git from process PATH"
        return $resolved
    }

    $localApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($localApplicationData)) {
        $desktopRoot = Join-Path $localApplicationData "GitHubDesktop"
        if (Test-Path -LiteralPath $desktopRoot -PathType Container) {
            $bundles = foreach ($directory in @(
                Get-ChildItem -LiteralPath $desktopRoot -Directory -Filter "app-*")) {
                $version = $null
                if ([Version]::TryParse(
                    $directory.Name.Substring(4), [ref]$version)) {
                    [pscustomobject]@{
                        Directory = $directory
                        Version = $version
                    }
                }
            }
            $bundles = @($bundles | Sort-Object -Property `
                @{ Expression = { $_.Version }; Descending = $true }, `
                @{ Expression = { $_.Directory.Name }; Descending = $true })
            foreach ($bundle in $bundles) {
                $candidate = Join-Path $bundle.Directory.FullName `
                    "resources\app\git\cmd\git.exe"
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return [IO.Path]::GetFullPath($candidate)
                }
            }
        }
    }

    throw "Git was not found. Install Git, keep GitHub Desktop installed, or set TERNARYCORE_GIT_EXECUTABLE to an absolute git.exe path."
}

function Get-TernaryCoreGitVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    $output = @(& $Executable --version 2>&1)
    $exitCode = $LASTEXITCODE
    $version = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($exitCode -ne 0) {
        throw "Git failed its version probe with exit code ${exitCode}: $Executable"
    }
    if ($version -notmatch '^git version\s+[^\r\n]+$') {
        throw "Git returned an unexpected version string from ${Executable}: '$version'"
    }
    return $version
}

$resolvedLockFile = (Resolve-Path -LiteralPath $LockFile).Path
$profile = Get-Content -LiteralPath $resolvedLockFile -Raw | ConvertFrom-Json
if ([int]$profile.schema_version -ne 1) {
    throw "Unsupported toolchain lock schema: $($profile.schema_version)"
}

$vivadoRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.vivado.root) -Label "Vivado root"
$vitisRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.vitis.root) -Label "Vitis root"
$armRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.arm_none_eabi_gcc.root) -Label "ARM GCC root"
$icarusRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.icarus.root) -Label "Icarus root"
$msys2Root = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.msys2_ucrt64.root) -Label "MSYS2 UCRT64 root"
$boardRepository = Resolve-LockedAbsolutePath -Path ([string]$profile.board_files.repository) -Label "Digilent board repository"
$boardRepoPath = Resolve-LockedChildPath -Parent $boardRepository -Path (
    [string]$profile.board_files.vivado_repo_path) -Label "Vivado board repository path"
$boardSparsePath = Resolve-LockedChildPath -Parent $boardRepository -Path (
    [string]$profile.board_files.sparse_path) -Label "Board sparse-checkout path"
$boardDefinitionDirectory = Resolve-LockedChildPath -Parent $boardRepository -Path (
    [string]$profile.board_files.definition_revision_directory) -Label "Board definition revision directory"
$workRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.runtime.work_root) -Label "Tool work root"
$evidenceRoot = Resolve-LockedAbsolutePath -Path ([string]$profile.runtime.evidence_root) -Label "Tool evidence root"

foreach ($pathRecord in @(
    @{ Path = $vivadoRoot; Label = "Vivado root" },
    @{ Path = $vitisRoot; Label = "Vitis root" },
    @{ Path = $armRoot; Label = "ARM GCC root" },
    @{ Path = $icarusRoot; Label = "Icarus root" },
    @{ Path = $msys2Root; Label = "MSYS2 UCRT64 root" },
    @{ Path = $boardRepository; Label = "Digilent board repository" },
    @{ Path = $boardRepoPath; Label = "Vivado board repository path" },
    @{ Path = $workRoot; Label = "Tool work root" },
    @{ Path = $evidenceRoot; Label = "Tool evidence root" }
)) {
    Assert-AbsolutePath -Path $pathRecord.Path -Label $pathRecord.Label
}

Assert-Directory -Path $vivadoRoot -Label "Vivado root"
Assert-Directory -Path $vitisRoot -Label "Vitis root"
Assert-Directory -Path $armRoot -Label "ARM GCC root"
Assert-Directory -Path $icarusRoot -Label "Icarus root"
Assert-Directory -Path $msys2Root -Label "MSYS2 UCRT64 root"
Assert-Directory -Path $boardRepository -Label "Digilent board repository"
Assert-Directory -Path $boardRepoPath -Label "Vivado board repository path"
Assert-Directory -Path $boardSparsePath -Label "Board sparse-checkout path"
Assert-Directory -Path $boardDefinitionDirectory -Label "Board definition revision directory"

$vivadoExecutable = Resolve-LockedChildPath -Parent $vivadoRoot -Path (
    [string]$profile.tools.vivado.executable) -Label "Vivado launcher"
$vitisExecutable = Resolve-LockedChildPath -Parent $vitisRoot -Path (
    [string]$profile.tools.vitis.executable) -Label "Vitis launcher"
$xsctExecutable = Resolve-LockedChildPath -Parent $vitisRoot -Path (
    [string]$profile.tools.vitis.xsct_executable) -Label "XSCT launcher"
$armExecutable = Resolve-LockedChildPath -Parent $armRoot -Path (
    [string]$profile.tools.arm_none_eabi_gcc.executable) -Label "ARM GCC"
$icarusBin = Resolve-LockedChildPath -Parent $icarusRoot -Path (
    [string]$profile.tools.icarus.bin_directory) -Label "Icarus bin directory"
$iverilogExecutable = Resolve-LockedChildPath -Parent $icarusRoot -Path (
    [string]$profile.tools.icarus.iverilog_executable) -Label "Icarus compiler"
$vvpExecutable = Resolve-LockedChildPath -Parent $icarusRoot -Path (
    [string]$profile.tools.icarus.vvp_executable) -Label "Icarus runtime"
$msys2Bin = Resolve-LockedChildPath -Parent $msys2Root -Path (
    [string]$profile.tools.msys2_ucrt64.bin_directory) -Label "MSYS2 UCRT64 bin directory"
$verilatorExecutable = Resolve-LockedChildPath -Parent $msys2Root -Path (
    [string]$profile.tools.msys2_ucrt64.verilator_executable) -Label "Verilator"
$makeExecutable = Resolve-LockedChildPath -Parent $msys2Root -Path (
    [string]$profile.tools.msys2_ucrt64.make_executable) -Label "GNU make"
$verilatorRoot = Resolve-LockedChildPath -Parent $msys2Root -Path (
    [string]$profile.tools.msys2_ucrt64.verilator_root_directory) -Label "Verilator root"
$pythonExecutable = Resolve-LockedAbsolutePath -Path ([string]$profile.python.executable) -Label "Python launcher"
$vivadoLibrary = Resolve-LockedChildPath -Parent $vivadoRoot -Path (
    [string]$profile.tools.vivado.library_directory) -Label "Vivado runtime library"

foreach ($boardFile in @($profile.board_files.files)) {
    Resolve-LockedChildPath -Parent $boardRepository -Path (
        [string]$boardFile.path) -Label "Pinned board definition" | Out-Null
}

foreach ($fileRecord in @(
    @{ Path = $vivadoExecutable; Label = "Vivado launcher" },
    @{ Path = $vitisExecutable; Label = "Vitis launcher" },
    @{ Path = $xsctExecutable; Label = "XSCT launcher" },
    @{ Path = $armExecutable; Label = "ARM GCC" },
    @{ Path = $iverilogExecutable; Label = "Icarus compiler" },
    @{ Path = $vvpExecutable; Label = "Icarus runtime" },
    @{ Path = $verilatorExecutable; Label = "Verilator" },
    @{ Path = $makeExecutable; Label = "GNU make" },
    @{ Path = $pythonExecutable; Label = "Python launcher" }
)) {
    Assert-File -Path $fileRecord.Path -Label $fileRecord.Label
}
Assert-Directory -Path $vivadoLibrary -Label "Vivado runtime library"
Assert-Directory -Path $msys2Bin -Label "MSYS2 UCRT64 bin directory"
Assert-Directory -Path $verilatorRoot -Label "Verilator root"
$gitExecutable = Resolve-TernaryCoreGitExecutable
$gitVersion = Get-TernaryCoreGitVersion -Executable $gitExecutable

New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

$prepend = @(
    (Split-Path -Parent $gitExecutable),
    $icarusBin,
    $msys2Bin,
    (Split-Path -Parent $armExecutable),
    (Split-Path -Parent $vitisExecutable),
    (Split-Path -Parent $vivadoExecutable),
    $vivadoLibrary
)
$existingPath = [Environment]::GetEnvironmentVariable("Path", "Process")
$pathEntries = @($prepend)
if (-not [string]::IsNullOrWhiteSpace($existingPath)) {
    $pathEntries += @($existingPath -split ";")
}
$seen = @{}
$deduplicatedPath = foreach ($entry in $pathEntries) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
        continue
    }
    $key = $entry.Trim().TrimEnd("\")
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        $entry.Trim()
    }
}
[Environment]::SetEnvironmentVariable(
    "Path", ($deduplicatedPath -join ";"), "Process")

[Environment]::SetEnvironmentVariable("XILINX_VIVADO", $vivadoRoot, "Process")
[Environment]::SetEnvironmentVariable("XILINX_VITIS", $vitisRoot, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_TOOLCHAIN_LOCK", $resolvedLockFile, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_GIT_EXECUTABLE", $gitExecutable, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_ICARUS_BIN", $icarusBin, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_VERILATOR", $verilatorExecutable, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_MAKE", $makeExecutable, "Process")
[Environment]::SetEnvironmentVariable(
    "VERILATOR_ROOT", $verilatorRoot, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_ARM_GCC", $armExecutable, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_PYTHON_EXE", $pythonExecutable, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_PYTHON_ARGS", ((@($profile.python.arguments) -join " ")), "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_WORK_ROOT", $workRoot, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_EVIDENCE_ROOT", $evidenceRoot, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_BOARD_FILES", $boardRepoPath, "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_ZYBO_BOARD_PART", ([string]$profile.board_files.board_part), "Process")
[Environment]::SetEnvironmentVariable(
    "TERNARYCORE_ZYBO_DEVICE_PART", ([string]$profile.board_files.device_part), "Process")

if ($PassThru) {
    [pscustomobject]@{
        Profile = [string]$profile.profile
        LockFile = $resolvedLockFile
        Vivado = $vivadoExecutable
        Vitis = $vitisExecutable
        Xsct = $xsctExecutable
        Git = $gitExecutable
        GitVersion = $gitVersion
        ArmGcc = $armExecutable
        IcarusBin = $icarusBin
        Verilator = $verilatorExecutable
        Make = $makeExecutable
        VerilatorRoot = $verilatorRoot
        Python = $pythonExecutable
        PythonArguments = @($profile.python.arguments)
        BoardFiles = $boardRepoPath
        WorkRoot = $workRoot
        EvidenceRoot = $evidenceRoot
        PathScope = "Process"
    }
}
