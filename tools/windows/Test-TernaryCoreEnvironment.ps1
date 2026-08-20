[CmdletBinding()]
param(
    [string]$LockFile = "",
    [string]$EvidenceDirectory = "",
    [switch]$StaticOnly,
    [switch]$SkipVivado,
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Test-TernaryCoreEnvironment.ps1 requires PowerShell 7 or newer (pwsh.exe) for safe path handling."
}

if ([string]::IsNullOrWhiteSpace($LockFile)) {
    $LockFile = Join-Path $PSScriptRoot "toolchain-2025.1.lock.json"
}

$failurePattern = (
    '(?im)^\s*(?:ERROR|FATAL|FAIL(?:ED)?|SIM_FAIL|TEST_FAIL)' +
    '(?:\s*(?::|=)|\s|$)|^\s*\*+\s*ERROR\b|\bASSERTION\s+FAILED\b')
$resolvedLockFile = (Resolve-Path -LiteralPath $LockFile).Path
$profile = Get-Content -LiteralPath $resolvedLockFile -Raw | ConvertFrom-Json
if ([int]$profile.schema_version -ne 1) {
    throw "Unsupported toolchain lock schema: $($profile.schema_version)"
}

function Assert-AbsolutePath {
    param([string]$Path, [string]$Label)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be an absolute path: $Path"
    }
}

function Resolve-LockedAbsolutePath {
    param([string]$Path, [string]$Label)

    Assert-AbsolutePath -Path $Path -Label $Label
    [IO.Path]::GetFullPath($Path)
}

function Write-GateLine {
    param([string]$Line)
    [Console]::Out.WriteLine($Line)
    Add-Content -LiteralPath $logPath -Value $Line -Encoding utf8
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label file not found: $Path"
    }
}

function Assert-Directory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label directory not found: $Path"
    }
}

function Assert-ReparseFreeDirectoryChain {
    param([string]$Path, [string]$Label)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "$Label is not a directory: $($item.FullName)"
    }
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label chain contains a reparse point: $($item.FullName)"
        }
        $item = $item.Parent
    }
}

function Resolve-SafeDDriveRoot {
    param([string]$Path, [string]$Label)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be a fully-qualified path: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals(
            $driveRoot, "D:\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be on D: to protect the system drive: $full"
    }
    if ([string]::Equals(
            $full, $driveRoot.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label cannot be a drive root: $full"
    }

    if (Test-Path -LiteralPath $full) {
        Assert-ReparseFreeDirectoryChain -Path $full -Label $Label
    }
    else {
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "$Label parent must already exist: $parent"
        }
        Assert-ReparseFreeDirectoryChain -Path $parent -Label "$Label parent"
    }
    $full
}

function Ensure-SafeDirectory {
    param([string]$Path, [string]$Label)

    $full = Resolve-SafeDDriveRoot -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null
    }
    Assert-ReparseFreeDirectoryChain -Path $full -Label $Label
    $full
}

function Ensure-SafeChildDirectory {
    param([string]$Parent, [string]$Child, [string]$Label)

    $parentFull = [IO.Path]::GetFullPath($Parent)
    $childFull = [IO.Path]::GetFullPath($Child)
    Assert-ChildPath -Parent $parentFull -Child $childFull -Label $Label
    Assert-ReparseFreeDirectoryChain -Path $parentFull -Label "$Label parent"
    if (-not (Test-Path -LiteralPath $childFull)) {
        New-Item -ItemType Directory -Path $childFull -ErrorAction Stop | Out-Null
    }
    Assert-ReparseFreeDirectoryChain -Path $childFull -Label $Label
    $childFull
}

function New-SafeUniqueDirectory {
    param([string]$Parent, [string]$Child, [string]$Label)

    $parentFull = [IO.Path]::GetFullPath($Parent)
    $childFull = [IO.Path]::GetFullPath($Child)
    Assert-ChildPath -Parent $parentFull -Child $childFull -Label $Label
    Assert-ReparseFreeDirectoryChain -Path $parentFull -Label "$Label parent"
    if (Test-Path -LiteralPath $childFull) {
        throw "$Label must be a brand-new path: $childFull"
    }
    New-Item -ItemType Directory -Path $childFull -ErrorAction Stop | Out-Null
    Assert-ReparseFreeDirectoryChain -Path $childFull -Label $Label
    $childFull
}

function Assert-ExpectedText {
    param([string]$Text, [string]$Pattern, [string]$Label)
    if ($Text -notmatch $Pattern) {
        throw "$Label did not match '$Pattern'"
    }
}

function Assert-ChildPath {
    param([string]$Parent, [string]$Child, [string]$Label)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd("\")
    $childFull = [IO.Path]::GetFullPath($Child)
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    if (-not $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside its allowed root: $childFull"
    }
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

function Resolve-NewEvidenceDirectoryPath {
    param([string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "Evidence directory must be a fully-qualified path: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Evidence directory cannot be a drive root: $full"
    }
    if (-not [string]::Equals($root, "D:\",
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Evidence directory must be on D: to protect the small system drive: $full"
    }
    if (Test-Path -LiteralPath $full) {
        throw "Evidence directory must be a brand-new path: $full"
    }

    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Evidence directory parent must already exist: $parent"
    }
    $ancestor = Get-Item -LiteralPath $parent -Force
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Evidence directory parent chain contains a reparse point: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    $full
}

function Test-PathWithin {
    param([string]$Candidate, [string]$Parent)

    $relative = [IO.Path]::GetRelativePath(
        [IO.Path]::GetFullPath($Parent),
        [IO.Path]::GetFullPath($Candidate))
    if ($relative -eq ".") {
        return $true
    }
    (-not [IO.Path]::IsPathRooted($relative)) -and
        ($relative -ne "..") -and
        (-not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)"))
}

function Test-PathsOverlap {
    param([string]$Left, [string]$Right)

    (Test-PathWithin -Candidate $Left -Parent $Right) -or
        (Test-PathWithin -Candidate $Right -Parent $Left)
}

function Remove-SafeOwnedWorkDirectory {
    param(
        [string]$Target,
        [string]$ExpectedParent,
        [string]$ExpectedLeaf,
        [string]$OwnerToken
    )

    $targetFull = [IO.Path]::GetFullPath($Target).TrimEnd("\")
    $expectedParentFull = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd("\")
    $expectedTarget = [IO.Path]::GetFullPath(
        (Join-Path $expectedParentFull $ExpectedLeaf)).TrimEnd("\")
    if (-not $targetFull.Equals(
            $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Environment-gate cleanup target is not the exact owned run directory: $targetFull"
    }
    Assert-ChildPath -Parent $expectedParentFull -Child $targetFull `
        -Label "Environment-gate cleanup target"
    Assert-ReparseFreeDirectoryChain -Path $targetFull `
        -Label "Environment-gate cleanup target"
    foreach ($protectedPath in @($protectedGitWorktrees) + @($EvidenceDirectory)) {
        if (Test-PathsOverlap -Left $targetFull -Right $protectedPath) {
            throw "Environment-gate cleanup target overlaps protected path ${protectedPath}: $targetFull"
        }
    }
    $ownerFile = Join-Path $targetFull ".ternarycore-run-owner"
    if (-not (Test-Path -LiteralPath $ownerFile -PathType Leaf)) {
        throw "Environment-gate cleanup ownership marker is absent: $ownerFile"
    }
    $recordedOwner = Get-Content -LiteralPath $ownerFile -Raw -ErrorAction Stop
    if (-not $recordedOwner.Equals($OwnerToken, [StringComparison]::Ordinal)) {
        throw "Environment-gate cleanup ownership marker does not match this run: $ownerFile"
    }
    $reparseEntries = @(Get-ChildItem -LiteralPath $targetFull -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($reparseEntries.Count -ne 0) {
        throw "Environment-gate cleanup tree contains a reparse point: $($reparseEntries[0].FullName)"
    }
    Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction Stop
}

function Find-GitExecutable {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "Git is not on PATH and LOCALAPPDATA is unavailable"
    }
    $candidates = @(Get-ChildItem -Path (
        Join-Path $env:LOCALAPPDATA "GitHubDesktop\app-*\resources\app\git\cmd\git.exe"
    ) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw "Git is not on PATH and GitHub Desktop bundled Git was not found"
    }
    $candidates[0].FullName
}

function Get-GitWorktreePaths {
    param(
        [string]$GitExecutable,
        [string]$RepositoryDirectory,
        [string]$Label
    )

    $lines = @(& $GitExecutable -C $RepositoryDirectory worktree list --porcelain 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "$Label Git worktree discovery failed: $($lines -join ' ')"
    }
    $paths = @($lines |
        Where-Object { $_ -like "worktree *" } |
        ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) })
    if ($paths.Count -eq 0) {
        throw "$Label Git worktree discovery returned no worktrees"
    }
    $paths
}

function Invoke-GateCommand {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $workDirectory,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-GateLine "COMMAND ${Label}: $FilePath $($Arguments -join ' ')"
    Push-Location $WorkingDirectory
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
    }
    finally {
        Pop-Location
    }
    foreach ($line in $lines) {
        Write-GateLine $line
    }
    $text = $lines -join "`n"
    if ($AllowedExitCodes -notcontains [int]$exitCode) {
        throw "$Label exited with code $exitCode"
    }
    if ($text -match $failurePattern) {
        throw "$Label emitted failure text"
    }
    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Lines = $lines
        Text = $text
    }
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
$vivadoExecutable = Resolve-LockedChildPath -Parent $vivadoRoot -Path (
    [string]$profile.tools.vivado.executable) -Label "Vivado launcher"
$vitisExecutable = Resolve-LockedChildPath -Parent $vitisRoot -Path (
    [string]$profile.tools.vitis.executable) -Label "Vitis launcher"
$xsctExecutable = Resolve-LockedChildPath -Parent $vitisRoot -Path (
    [string]$profile.tools.vitis.xsct_executable) -Label "XSCT launcher"
$armExecutable = Resolve-LockedChildPath -Parent $armRoot -Path (
    [string]$profile.tools.arm_none_eabi_gcc.executable) -Label "ARM GCC"
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
$installerPath = Resolve-LockedAbsolutePath -Path ([string]$profile.tools.icarus.installer) -Label "Icarus installer"
$vivadoValidationScript = Join-Path $PSScriptRoot "validate_vivado_2025_1.tcl"

$runId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-$PID-" + (
    [guid]::NewGuid().ToString("N").Substring(0, 8))
$workDirectoryLeaf = "environment-gate-$runId"
$workOwnerToken = [guid]::NewGuid().ToString("N")
$workRoot = Resolve-SafeDDriveRoot -Path ([string]$profile.runtime.work_root) `
    -Label "Environment-gate work root"
$workDirectory = [IO.Path]::GetFullPath(
    (Join-Path $workRoot $workDirectoryLeaf))
$usingDefaultEvidenceDirectory = [string]::IsNullOrWhiteSpace($EvidenceDirectory)
if ($usingDefaultEvidenceDirectory) {
    $evidenceRoot = Resolve-SafeDDriveRoot -Path (
        [string]$profile.runtime.evidence_root) `
        -Label "Environment-gate evidence root"
    $evidenceCategory = [IO.Path]::GetFullPath(
        (Join-Path $evidenceRoot "environment-gate"))
    $EvidenceDirectory = [IO.Path]::GetFullPath(
        (Join-Path $evidenceCategory $runId))
}
else {
    $EvidenceDirectory = Resolve-NewEvidenceDirectoryPath -Path $EvidenceDirectory
}

if (Test-PathsOverlap -Left $EvidenceDirectory -Right $workRoot) {
    throw "Evidence directory must be disjoint from the environment-gate work root: $workRoot"
}
if (Test-PathsOverlap -Left $EvidenceDirectory -Right $workDirectory) {
    throw "Evidence directory must be disjoint from the environment-gate work directory: $workDirectory"
}

$gitExecutable = Find-GitExecutable
$protectedGitWorktrees = @(
    Get-GitWorktreePaths -GitExecutable $gitExecutable `
        -RepositoryDirectory $PSScriptRoot -Label "TernaryCore"
    Get-GitWorktreePaths -GitExecutable $gitExecutable `
        -RepositoryDirectory $boardRepository -Label "Digilent board repository"
) | Sort-Object -Unique
foreach ($gitWorktree in $protectedGitWorktrees) {
    foreach ($candidate in @(
        @{ Path = $workRoot; Label = "Environment-gate work root" },
        @{ Path = $EvidenceDirectory; Label = "Evidence directory" }
    )) {
        if (Test-PathsOverlap -Left ([string]$candidate.Path) -Right $gitWorktree) {
            throw "$($candidate.Label) overlaps protected Git worktree ${gitWorktree}: $($candidate.Path)"
        }
    }
}

$workRoot = Ensure-SafeDirectory -Path $workRoot `
    -Label "Environment-gate work root"
if ($usingDefaultEvidenceDirectory) {
    $evidenceRoot = Ensure-SafeDirectory -Path $evidenceRoot `
        -Label "Environment-gate evidence root"
    $evidenceCategory = Ensure-SafeChildDirectory -Parent $evidenceRoot `
        -Child $evidenceCategory -Label "Environment-gate evidence category"
    $EvidenceDirectory = Resolve-NewEvidenceDirectoryPath -Path $EvidenceDirectory
}
$EvidenceDirectory = New-SafeUniqueDirectory `
    -Parent (Split-Path -Parent $EvidenceDirectory) `
    -Child $EvidenceDirectory -Label "Environment-gate evidence directory"
$workDirectory = New-SafeUniqueDirectory -Parent $workRoot `
    -Child $workDirectory -Label "Environment-gate work directory"
Set-Content -LiteralPath (Join-Path $workDirectory ".ternarycore-run-owner") `
    -Value $workOwnerToken -Encoding ascii -NoNewline
$logPath = Join-Path $EvidenceDirectory "environment-gate.log"
$jsonPath = Join-Path $EvidenceDirectory "ENVIRONMENT.json"
Set-Content -LiteralPath $logPath -Value "" -Encoding utf8

$userPathBefore = [Environment]::GetEnvironmentVariable("Path", "User")
$machinePathBefore = [Environment]::GetEnvironmentVariable("Path", "Machine")
$results = [ordered]@{
    schema_version = "ternarycore-environment-1.0"
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
    profile = [string]$profile.profile
    lock_file = $resolvedLockFile
    lock_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedLockFile).Hash.ToLowerInvariant()
    static_only = [bool]$StaticOnly
    skip_vivado = [bool]$SkipVivado
    tools = [ordered]@{}
    board_files = [ordered]@{}
    paths = [ordered]@{
        work_directory = $workDirectory
        evidence_directory = $EvidenceDirectory
    }
    passed = $false
}
$caughtFailure = $null

try {
    Write-GateLine "ENVIRONMENT_GATE_START profile=$($profile.profile)"
    foreach ($directoryRecord in @(
        @{ Path = $vivadoRoot; Label = "Vivado root" },
        @{ Path = $vitisRoot; Label = "Vitis root" },
        @{ Path = $armRoot; Label = "ARM GCC root" },
        @{ Path = $icarusRoot; Label = "Icarus root" },
        @{ Path = $msys2Root; Label = "MSYS2 UCRT64 root" },
        @{ Path = $msys2Bin; Label = "MSYS2 UCRT64 bin directory" },
        @{ Path = $verilatorRoot; Label = "Verilator root" },
        @{ Path = $boardRepository; Label = "Digilent board repository" },
        @{ Path = $boardRepoPath; Label = "Vivado board repository path" },
        @{ Path = $boardSparsePath; Label = "Board sparse-checkout path" },
        @{ Path = $boardDefinitionDirectory; Label = "Board definition revision directory" }
    )) {
        Assert-Directory -Path $directoryRecord.Path -Label $directoryRecord.Label
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
        @{ Path = $pythonExecutable; Label = "Python launcher" },
        @{ Path = $installerPath; Label = "Icarus installer" },
        @{ Path = $vivadoValidationScript; Label = "Vivado validation script" }
    )) {
        Assert-File -Path $fileRecord.Path -Label $fileRecord.Label
    }

    $installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installerPath).Hash.ToLowerInvariant()
    if ($installerHash -ne ([string]$profile.tools.icarus.installer_sha256).ToLowerInvariant()) {
        throw "Icarus installer hash mismatch"
    }

    $boardHashes = @()
    foreach ($boardFile in @($profile.board_files.files)) {
        $boardFilePath = Resolve-LockedChildPath -Parent $boardRepository -Path (
            [string]$boardFile.path) -Label "Pinned board definition"
        Assert-File -Path $boardFilePath -Label "Pinned board definition"
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $boardFilePath).Hash.ToLowerInvariant()
        $expectedHash = ([string]$boardFile.sha256).ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Board definition hash mismatch: $boardFilePath"
        }
        $boardHashes += [ordered]@{
            path = [string]$boardFile.path
            sha256 = $actualHash
        }
    }

    $gitHead = Invoke-GateCommand -Label "board git HEAD" -FilePath $gitExecutable -Arguments @(
        "-C", $boardRepository, "rev-parse", "HEAD")
    $actualHead = $gitHead.Text.Trim()
    if ($actualHead -ne [string]$profile.board_files.commit) {
        throw "Board repository commit mismatch: $actualHead"
    }
    $gitStatus = Invoke-GateCommand -Label "board git status" -FilePath $gitExecutable -Arguments @(
        "-C", $boardRepository, "status", "--porcelain")
    if (-not [string]::IsNullOrWhiteSpace($gitStatus.Text)) {
        throw "Board repository is dirty"
    }
    $gitRemote = Invoke-GateCommand -Label "board git remote" -FilePath $gitExecutable -Arguments @(
        "-C", $boardRepository, "remote", "get-url", "origin")
    if ($gitRemote.Text.Trim() -ne [string]$profile.board_files.remote) {
        throw "Board repository remote mismatch: $($gitRemote.Text.Trim())"
    }
    $gitSparse = Invoke-GateCommand -Label "board sparse checkout" -FilePath $gitExecutable -Arguments @(
        "-C", $boardRepository, "sparse-checkout", "list")
    if (@($gitSparse.Lines) -notcontains [string]$profile.board_files.sparse_path) {
        throw "Pinned sparse-checkout path is absent"
    }
    $gitSymbolic = Invoke-GateCommand -Label "board detached HEAD" -FilePath $gitExecutable -Arguments @(
        "-C", $boardRepository, "symbolic-ref", "-q", "HEAD") -AllowedExitCodes @(0, 1)
    if ($gitSymbolic.ExitCode -ne 1) {
        throw "Board repository must be checked out at a detached commit"
    }

    $results.board_files = [ordered]@{
        repository = $boardRepository
        remote = $gitRemote.Text.Trim()
        commit = $actualHead
        sparse_path = [string]$profile.board_files.sparse_path
        vivado_repo_path = $boardRepoPath
        board_part = [string]$profile.board_files.board_part
        device_part = [string]$profile.board_files.device_part
        files = $boardHashes
    }
    $results.tools.icarus_installer = [ordered]@{
        path = $installerPath
        sha256 = $installerHash
    }

    if (-not $StaticOnly) {
        $iverilogVersion = Invoke-GateCommand -Label "Icarus version" -FilePath $iverilogExecutable -Arguments @("-V")
        Assert-ExpectedText -Text $iverilogVersion.Text -Pattern (
            "Icarus Verilog version\s+" + [regex]::Escape([string]$profile.tools.icarus.version)) -Label "Icarus version"

        $vvpVersion = Invoke-GateCommand -Label "VVP version" -FilePath $vvpExecutable -Arguments @("-V")
        Assert-ExpectedText -Text $vvpVersion.Text -Pattern "Icarus Verilog runtime version" -Label "VVP version"

        $verilatorVersion = Invoke-GateCommand -Label "Verilator version" -FilePath $verilatorExecutable -Arguments @("--version")
        Assert-ExpectedText -Text $verilatorVersion.Text -Pattern (
            "Verilator\s+" + [regex]::Escape([string]$profile.tools.msys2_ucrt64.verilator_version)) -Label "Verilator version"

        $makeVersion = Invoke-GateCommand -Label "GNU make version" -FilePath $makeExecutable -Arguments @("--version")
        Assert-ExpectedText -Text $makeVersion.Text -Pattern (
            "GNU Make\s+" + [regex]::Escape([string]$profile.tools.msys2_ucrt64.make_version)) -Label "GNU make version"

        $armVersion = Invoke-GateCommand -Label "ARM GCC version" -FilePath $armExecutable -Arguments @("--version")
        Assert-ExpectedText -Text $armVersion.Text -Pattern ([regex]::Escape(
            [string]$profile.tools.arm_none_eabi_gcc.version)) -Label "ARM GCC version"

        $xsctVersion = Invoke-GateCommand -Label "XSCT smoke" -FilePath $xsctExecutable -Arguments @(
            "-eval", 'puts "TERNARYCORE_XSCT_GATE_PASS"; exit')
        Assert-ExpectedText -Text $xsctVersion.Text -Pattern (
            "XSCT\) v" + [regex]::Escape([string]$profile.tools.vitis.xsct_version)) -Label "XSCT version"
        Assert-ExpectedText -Text $xsctVersion.Text -Pattern "TERNARYCORE_XSCT_GATE_PASS" -Label "XSCT smoke"

        # The 2025.1 launcher may return 1 for a successful version-only query,
        # so the banner and failure text are authoritative for this one probe.
        $vitisVersion = Invoke-GateCommand -Label "Vitis version" -FilePath $vitisExecutable -Arguments @("-v") -AllowedExitCodes @(0, 1)
        Assert-ExpectedText -Text $vitisVersion.Text -Pattern (
            "Vitis v" + [regex]::Escape([string]$profile.tools.vitis.version)) -Label "Vitis version"

        $pythonArguments = @($profile.python.arguments | ForEach-Object { [string]$_ })
        $pythonSmoke = Invoke-GateCommand -Label "Python NumPy smoke" -FilePath $pythonExecutable -Arguments (
            @($pythonArguments) + @(
                "-c",
                "import sys,numpy; print('TERNARYCORE_PYTHON_GATE_PASS'); print(sys.version.split()[0]); print(numpy.__version__)"))
        Assert-ExpectedText -Text $pythonSmoke.Text -Pattern "TERNARYCORE_PYTHON_GATE_PASS" -Label "Python smoke"
        Assert-ExpectedText -Text $pythonSmoke.Text -Pattern (
            "(?m)^" + [regex]::Escape([string]$profile.python.version_prefix)) -Label "Python version"

        $iverilogSource = Join-Path $workDirectory "iverilog_smoke.v"
        $iverilogOutput = Join-Path $workDirectory "iverilog_smoke.vvp"
        @'
module iverilog_smoke;
  initial begin
    $display("TERNARYCORE_ICARUS_GATE_PASS");
    $finish;
  end
endmodule
'@ | Set-Content -LiteralPath $iverilogSource -Encoding ascii
        Invoke-GateCommand -Label "Icarus compile smoke" -FilePath $iverilogExecutable -Arguments @(
            "-g2012", "-o", $iverilogOutput, $iverilogSource) | Out-Null
        $vvpSmoke = Invoke-GateCommand -Label "Icarus runtime smoke" -FilePath $vvpExecutable -Arguments @($iverilogOutput)
        Assert-ExpectedText -Text $vvpSmoke.Text -Pattern "TERNARYCORE_ICARUS_GATE_PASS" -Label "Icarus runtime smoke"

        [Environment]::SetEnvironmentVariable("VERILATOR_ROOT", $verilatorRoot, "Process")
        Invoke-GateCommand -Label "Verilator lint smoke" -FilePath $verilatorExecutable -Arguments @(
            "--lint-only", "--timing", "-Wall", "-Wno-fatal", $iverilogSource) | Out-Null

        $armSource = Join-Path $workDirectory "cortex_a9_smoke.c"
        $armObject = Join-Path $workDirectory "cortex_a9_smoke.o"
        "int main(void) { return 0; }" | Set-Content -LiteralPath $armSource -Encoding ascii
        Invoke-GateCommand -Label "Cortex-A9 compile smoke" -FilePath $armExecutable -Arguments @(
            "-mcpu=cortex-a9", "-marm", "-ffreestanding", "-c", $armSource, "-o", $armObject) | Out-Null
        Assert-File -Path $armObject -Label "Cortex-A9 smoke object"

        $results.tools.icarus = [ordered]@{
            executable = $iverilogExecutable
            version = [string]$profile.tools.icarus.version
        }
        $results.tools.verilator = [ordered]@{
            executable = $verilatorExecutable
            version = [string]$profile.tools.msys2_ucrt64.verilator_version
            package = [string]$profile.tools.msys2_ucrt64.verilator_package
        }
        $results.tools.gnu_make = [ordered]@{
            executable = $makeExecutable
            version = [string]$profile.tools.msys2_ucrt64.make_version
            package = [string]$profile.tools.msys2_ucrt64.make_package
        }
        $results.tools.arm_none_eabi_gcc = [ordered]@{
            executable = $armExecutable
            version = [string]$profile.tools.arm_none_eabi_gcc.version
            target_cpu = [string]$profile.tools.arm_none_eabi_gcc.target_cpu
        }
        $results.tools.vitis = [ordered]@{
            executable = $vitisExecutable
            version = [string]$profile.tools.vitis.version
            xsct = $xsctExecutable
            xsct_version = [string]$profile.tools.vitis.xsct_version
        }
        $results.tools.python = [ordered]@{
            executable = $pythonExecutable
            arguments = $pythonArguments
            version_prefix = [string]$profile.python.version_prefix
            required_modules = @($profile.python.required_modules)
        }

        if (-not $SkipVivado) {
            $vivadoGate = Invoke-GateCommand -Label "Vivado board gate" -FilePath $vivadoExecutable -Arguments @(
                "-mode", "batch", "-nolog", "-nojournal", "-notrace",
                "-source", $vivadoValidationScript, "-tclargs",
                $boardRepoPath,
                [string]$profile.tools.vivado.version,
                [string]$profile.board_files.board_part,
                [string]$profile.board_files.device_part)
            Assert-ExpectedText -Text $vivadoGate.Text -Pattern "TERNARYCORE_VIVADO_GATE_PASS" -Label "Vivado board gate"
            $results.tools.vivado = [ordered]@{
                executable = $vivadoExecutable
                version = [string]$profile.tools.vivado.version
                board_gate = "PASS"
            }
        }
        else {
            $results.tools.vivado = [ordered]@{
                executable = $vivadoExecutable
                version = [string]$profile.tools.vivado.version
                board_gate = "SKIPPED"
            }
        }
    }

    if ([Environment]::GetEnvironmentVariable("Path", "User") -ne $userPathBefore) {
        throw "User PATH changed during the environment gate"
    }
    if ([Environment]::GetEnvironmentVariable("Path", "Machine") -ne $machinePathBefore) {
        throw "Machine PATH changed during the environment gate"
    }

    if (-not $KeepWork) {
        Remove-SafeOwnedWorkDirectory -Target $workDirectory `
            -ExpectedParent $workRoot -ExpectedLeaf $workDirectoryLeaf `
            -OwnerToken $workOwnerToken
    }
    Write-GateLine "ENVIRONMENT_GATE_PASS evidence=$EvidenceDirectory"
    $results.passed = $true
}
catch {
    $caughtFailure = $_
    Write-GateLine "ENVIRONMENT_GATE_FAILED $($_.Exception.Message)"
}
finally {
    $results.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    $workRetained = Test-Path -LiteralPath $workDirectory -PathType Container
    $results.paths.work_retained = [bool]$workRetained
    if ($null -ne $caughtFailure) {
        $results.failure = $caughtFailure.Exception.Message
    }
    $results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

    if ($workRetained) {
        Write-GateLine "ENVIRONMENT_GATE_WORK $workDirectory"
    }
}

if ($null -ne $caughtFailure) {
    throw $caughtFailure
}

Write-Output "ENVIRONMENT_JSON $jsonPath"
