[CmdletBinding()]
param(
    [string]$IcarusBin = "",
    [switch]$KvOnly,
    [switch]$SkipPython,
    [string]$PythonExecutable = "",
    [string[]]$PythonArguments = @(),
    [string]$WorkRoot = "",
    [string]$EvidenceRoot = "",
    [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "run_windows_regression.ps1 requires PowerShell 7 or newer (pwsh.exe) for safe path handling."
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pythonArgumentsWereBound = $PSBoundParameters.ContainsKey("PythonArguments")
$failurePattern = (
    '(?im)^\s*(?:ERROR|FATAL|FAIL(?:ED)?|SIM_FAIL|TEST_FAIL)' +
    '(?:\s*(?::|=)|\s|$)|^\s*\*+\s*ERROR\b|\bASSERTION\s+FAILED\b|' +
    '^\s*TIMEOUT(?:\s*(?::|=)|\s|$)|' +
    '^\s*(?:[-=]+\s*|RESULT\s*:\s*)?[1-9][0-9]*' +
    '(?:\s+[A-Za-z0-9_.-]+)*\s+error(?:s|\(s\))?(?:\s*[-=]+)?\s*$')
$defaultSimulationPassPattern = '(?im)^\s*(?:TB PASS\b|ALL TESTS PASSED\b)'

function Assert-AbsolutePath {
    param([string]$Path, [string]$Label)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be an absolute path: $Path"
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

function Test-PathWithinOrEqual {
    param([string]$Candidate, [string]$Root)

    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd("\")
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    if ($candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathsOverlap {
    param([string]$Left, [string]$Right)

    (Test-PathWithinOrEqual -Candidate $Left -Root $Right) -or
        (Test-PathWithinOrEqual -Candidate $Right -Root $Left)
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

function Find-GitExecutable {
    $command = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command "git" -ErrorAction SilentlyContinue
    }
    if ($null -ne $command) {
        return [IO.Path]::GetFullPath($command.Source)
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
    [IO.Path]::GetFullPath($candidates[0].FullName)
}

function Get-GitWorktreePaths {
    param(
        [string]$GitExecutable,
        [string]$RepositoryDirectory,
        [string]$Label
    )

    $lines = @(& $GitExecutable -C $RepositoryDirectory worktree list --porcelain 2>&1 |
        ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ([int]$exitCode -ne 0) {
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

function Remove-SafeOwnedRunDirectory {
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
        throw "Regression cleanup target is not the exact owned run directory: $targetFull"
    }
    Assert-ChildPath -Parent $expectedParentFull -Child $targetFull `
        -Label "Regression cleanup target"
    Assert-ReparseFreeDirectoryChain -Path $targetFull `
        -Label "Regression cleanup target"
    foreach ($protectedPath in @($protectedGitWorktrees) + @($EvidenceRoot)) {
        if (Test-PathsOverlap -Left $targetFull -Right $protectedPath) {
            throw "Regression cleanup target overlaps protected path ${protectedPath}: $targetFull"
        }
    }
    $ownerFile = Join-Path $targetFull ".ternarycore-run-owner"
    if (-not (Test-Path -LiteralPath $ownerFile -PathType Leaf)) {
        throw "Regression cleanup ownership marker is absent: $ownerFile"
    }
    $recordedOwner = Get-Content -LiteralPath $ownerFile -Raw -ErrorAction Stop
    if (-not $recordedOwner.Equals($OwnerToken, [StringComparison]::Ordinal)) {
        throw "Regression cleanup ownership marker does not match this run: $ownerFile"
    }
    $reparseEntries = @(Get-ChildItem -LiteralPath $targetFull -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    if ($reparseEntries.Count -ne 0) {
        throw "Regression cleanup tree contains a reparse point: $($reparseEntries[0].FullName)"
    }
    Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction Stop
}

if ([string]::IsNullOrWhiteSpace($IcarusBin)) {
    $IcarusBin = [Environment]::GetEnvironmentVariable(
        "TERNARYCORE_ICARUS_BIN", "Process")
}
if ([string]::IsNullOrWhiteSpace($IcarusBin)) {
    $iverilogCommand = Get-Command "iverilog.exe" -ErrorAction SilentlyContinue
    if ($null -eq $iverilogCommand) {
        $iverilogCommand = Get-Command "iverilog" -ErrorAction SilentlyContinue
    }
    if ($null -eq $iverilogCommand) {
        throw "Icarus is unresolved. Dot-source tools\windows\Enter-TernaryCoreEnvironment.ps1 or pass -IcarusBin."
    }
    $IcarusBin = Split-Path -Parent $iverilogCommand.Source
}
$IcarusBin = [IO.Path]::GetFullPath($IcarusBin)
$iverilog = Join-Path $IcarusBin "iverilog.exe"
$vvp = Join-Path $IcarusBin "vvp.exe"
if (-not (Test-Path -LiteralPath $iverilog -PathType Leaf)) {
    throw "Icarus compiler not found: $iverilog"
}
if (-not (Test-Path -LiteralPath $vvp -PathType Leaf)) {
    throw "Icarus runtime not found: $vvp"
}

if (-not $SkipPython) {
    $pythonExecutableFromLockedEnvironment = $false
    if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
        $PythonExecutable = [Environment]::GetEnvironmentVariable(
            "TERNARYCORE_PYTHON_EXE", "Process")
        $pythonExecutableFromLockedEnvironment = -not (
            [string]::IsNullOrWhiteSpace($PythonExecutable))
    }
    if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
        $pythonCommand = Get-Command "py.exe" -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            $pythonCommand = Get-Command "python.exe" -ErrorAction SilentlyContinue
        }
        if ($null -eq $pythonCommand) {
            throw "Python is unresolved. Enter the locked environment or pass -PythonExecutable."
        }
        $PythonExecutable = $pythonCommand.Source
    }
    $PythonExecutable = [IO.Path]::GetFullPath($PythonExecutable)
    if (-not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf)) {
        throw "Python launcher not found: $PythonExecutable"
    }
    if (-not $pythonArgumentsWereBound) {
        if ($pythonExecutableFromLockedEnvironment) {
            $lockedPythonArguments = [Environment]::GetEnvironmentVariable(
                "TERNARYCORE_PYTHON_ARGS", "Process")
            if (-not [string]::IsNullOrWhiteSpace($lockedPythonArguments)) {
                $PythonArguments = @($lockedPythonArguments -split "\s+" | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) })
            }
        }
        if (@($PythonArguments).Count -eq 0 -and
            (Split-Path -Leaf $PythonExecutable) -match '^py(?:\.exe)?$') {
            $PythonArguments = @("-3.12")
        }
    }
}

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = [Environment]::GetEnvironmentVariable(
        "TERNARYCORE_WORK_ROOT", "Process")
}
if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = "D:\tc-work\ternarycore"
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = [Environment]::GetEnvironmentVariable(
        "TERNARYCORE_EVIDENCE_ROOT", "Process")
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = "D:\tc-logs\ternarycore"
}
$WorkRoot = Resolve-SafeDDriveRoot -Path $WorkRoot -Label "Regression work root"
$EvidenceRoot = Resolve-SafeDDriveRoot -Path $EvidenceRoot -Label "Regression evidence root"
if (Test-PathsOverlap -Left $WorkRoot -Right $EvidenceRoot) {
    throw "Regression work and evidence roots must not be equal or nested: work='$WorkRoot', evidence='$EvidenceRoot'"
}

$environmentLockPath = Join-Path $repo "tools/windows/toolchain-2025.1.lock.json"
if (-not (Test-Path -LiteralPath $environmentLockPath -PathType Leaf)) {
    throw "Environment lock not found: $environmentLockPath"
}
$environmentProfile = Get-Content -LiteralPath $environmentLockPath -Raw |
    ConvertFrom-Json
$boardRepository = [IO.Path]::GetFullPath(
    [string]$environmentProfile.board_files.repository)
if (-not (Test-Path -LiteralPath $boardRepository -PathType Container)) {
    throw "Pinned board repository not found: $boardRepository"
}
$gitExecutable = Find-GitExecutable
$protectedGitWorktrees = @(
    Get-GitWorktreePaths -GitExecutable $gitExecutable `
        -RepositoryDirectory $repo -Label "TernaryCore"
    Get-GitWorktreePaths -GitExecutable $gitExecutable `
        -RepositoryDirectory $boardRepository -Label "Digilent board repository"
) | Sort-Object -Unique
foreach ($gitWorktree in $protectedGitWorktrees) {
    foreach ($candidate in @(
        @{ Path = $WorkRoot; Label = "Regression work root" },
        @{ Path = $EvidenceRoot; Label = "Regression evidence root" }
    )) {
        if (Test-PathsOverlap -Left ([string]$candidate.Path) -Right $gitWorktree) {
            throw "$($candidate.Label) overlaps protected Git worktree ${gitWorktree}: $($candidate.Path)"
        }
    }
}

$WorkRoot = Ensure-SafeDirectory -Path $WorkRoot -Label "Regression work root"
$EvidenceRoot = Ensure-SafeDirectory -Path $EvidenceRoot -Label "Regression evidence root"
$workCategory = Ensure-SafeChildDirectory -Parent $WorkRoot `
    -Child (Join-Path $WorkRoot "windows-regression") `
    -Label "Regression work category"
$evidenceCategory = Ensure-SafeChildDirectory -Parent $EvidenceRoot `
    -Child (Join-Path $EvidenceRoot "windows-regression") `
    -Label "Regression evidence category"

$runId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-$PID-" + (
    [guid]::NewGuid().ToString("N").Substring(0, 8))
$runOwnerToken = [guid]::NewGuid().ToString("N")
$runWorkDirectory = Join-Path $workCategory $runId
$simTemp = Join-Path $runWorkDirectory "scratch"
$runEvidenceDirectory = Join-Path $evidenceCategory $runId
$runWorkDirectory = New-SafeUniqueDirectory -Parent $workCategory `
    -Child $runWorkDirectory -Label "Regression work directory"
Set-Content -LiteralPath (Join-Path $runWorkDirectory ".ternarycore-run-owner") `
    -Value $runOwnerToken -Encoding ascii -NoNewline
$simTemp = New-SafeUniqueDirectory -Parent $runWorkDirectory `
    -Child $simTemp -Label "Regression scratch directory"
$runEvidenceDirectory = New-SafeUniqueDirectory -Parent $evidenceCategory `
    -Child $runEvidenceDirectory -Label "Regression evidence directory"
$logPath = Join-Path $runEvidenceDirectory "windows-regression.log"
$summaryPath = Join-Path $runEvidenceDirectory "summary.json"
Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
$completedSimulations = New-Object 'Collections.Generic.List[string]'
$completedPythonTests = New-Object 'Collections.Generic.List[string]'
$sourceManifestPath = Join-Path $runEvidenceDirectory "source-manifest.json"
$provenancePath = Join-Path $runEvidenceDirectory "provenance.json"
$gitStatusStartPath = Join-Path $runEvidenceDirectory "git-status-start.porcelain-v1.txt"
$gitStatusFinalPath = Join-Path $runEvidenceDirectory "git-status-final.porcelain-v1.txt"
$sourceFiles = @{}
$sourceTrees = @{}
$toolFiles = [ordered]@{}
$sourceStabilityVerified = $false
$sourceManifestSha256 = $null
$provenanceSha256 = $null
$gitFinal = $null

function Write-RunLine {
    param([string]$Line)
    [Console]::Out.WriteLine($Line)
    Add-Content -LiteralPath $logPath -Value $Line -Encoding utf8
}

function Get-RepositoryRelativePath {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $repoRoot = $repo.TrimEnd("\")
    $repoPrefix = $repoRoot + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoPrefix.Length).Replace("\", "/")
    }
    if ($fullPath.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }
    return $null
}

function New-Sha256Record {
    param([string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Provenance input is not a file: $resolvedPath"
    }
    $item = Get-Item -LiteralPath $resolvedPath
    [ordered]@{
        absolute_path = [IO.Path]::GetFullPath($resolvedPath)
        repository_relative_path = Get-RepositoryRelativePath -Path $resolvedPath
        length_bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-Sha256RecordStable {
    param(
        [System.Collections.IDictionary]$Record,
        [string]$Label
    )

    $path = [string]$Record.absolute_path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Label disappeared during the regression: $path"
    }
    $current = New-Sha256Record -Path $path
    if ([long]$current.length_bytes -ne [long]$Record.length_bytes -or
        -not ([string]$current.sha256).Equals(
            [string]$Record.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label changed during the regression: $path"
    }
}

function Register-SourceFile {
    param([string]$Path, [string]$Role)

    $record = New-Sha256Record -Path $Path
    $key = ([string]$record.absolute_path).ToUpperInvariant()
    if ($sourceFiles.ContainsKey($key)) {
        $existing = $sourceFiles[$key]
        Assert-Sha256RecordStable -Record $existing -Label "Source input"
        $existing.roles = @(
            (@($existing.roles) + @($Role)) | Sort-Object -Unique)
        return
    }
    $record.roles = @($Role)
    $sourceFiles[$key] = $record
}

function Register-SourceTree {
    param([string]$Path, [string]$Role)

    $resolvedRoot = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Runtime provenance tree is not a directory: $resolvedRoot"
    }
    $resolvedRoot = [IO.Path]::GetFullPath($resolvedRoot)
    $memberPaths = @(
        Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse |
            Sort-Object FullName |
            ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
    if ($memberPaths.Count -eq 0) {
        throw "Runtime provenance tree is empty: $resolvedRoot"
    }
    $key = $resolvedRoot.ToUpperInvariant()
    if ($sourceTrees.ContainsKey($key)) {
        $existing = $sourceTrees[$key]
        $membershipDelta = @(Compare-Object -ReferenceObject @($existing.member_paths) `
            -DifferenceObject $memberPaths)
        if ($membershipDelta.Count -ne 0) {
            throw "Runtime provenance tree membership changed before reuse: $resolvedRoot"
        }
        $existing.roles = @(
            (@($existing.roles) + @($Role)) | Sort-Object -Unique)
    }
    else {
        $sourceTrees[$key] = [ordered]@{
            absolute_path = $resolvedRoot
            repository_relative_path = Get-RepositoryRelativePath -Path $resolvedRoot
            member_paths = @($memberPaths)
            roles = @($Role)
        }
    }
    foreach ($memberPath in $memberPaths) {
        Register-SourceFile -Path $memberPath -Role $Role
    }
}

function Register-ToolFile {
    param([string]$Name, [string]$Path)

    $record = New-Sha256Record -Path $Path
    $record.name = $Name
    $toolFiles[$Name] = $record
}

function Get-GitText {
    param([string[]]$Arguments)

    $lines = @(& $gitExecutable -C $repo @Arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ([int]$exitCode -ne 0) {
        throw "git $($Arguments -join ' ') exited with code $exitCode`: $($lines -join ' ')"
    }
    $lines -join "`n"
}

function Get-GitSnapshot {
    $head = (Get-GitText -Arguments @("rev-parse", "HEAD")).Trim()
    $branch = (Get-GitText -Arguments @(
        "rev-parse", "--abbrev-ref", "HEAD")).Trim()
    $porcelain = Get-GitText -Arguments @(
        "status", "--porcelain=v1", "--untracked-files=all")
    [ordered]@{
        captured_utc = (Get-Date).ToUniversalTime().ToString("o")
        head = $head
        branch = $branch
        detached = $branch.Equals("HEAD", [StringComparison]::Ordinal)
        dirty = -not [string]::IsNullOrEmpty($porcelain)
        porcelain_v1 = $porcelain
    }
}

function Assert-ProvenanceStable {
    foreach ($record in @($sourceFiles.Values)) {
        Assert-Sha256RecordStable -Record $record -Label "Source input"
    }
    foreach ($tree in @($sourceTrees.Values)) {
        $currentMembers = @(
            Get-ChildItem -LiteralPath ([string]$tree.absolute_path) -File -Recurse |
                Sort-Object FullName |
                ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
        $membershipDelta = @(Compare-Object -ReferenceObject @($tree.member_paths) `
            -DifferenceObject $currentMembers)
        if ($membershipDelta.Count -ne 0) {
            throw "Runtime provenance tree membership changed during the regression: $($tree.absolute_path)"
        }
    }
    foreach ($record in @($toolFiles.Values)) {
        Assert-Sha256RecordStable -Record $record -Label "Tool executable"
    }

    $script:gitFinal = Get-GitSnapshot
    if (-not ([string]$gitFinal.head).Equals(
            [string]$gitStart.head, [StringComparison]::Ordinal) -or
        -not ([string]$gitFinal.branch).Equals(
            [string]$gitStart.branch, [StringComparison]::Ordinal)) {
        throw "Git HEAD or branch changed during the regression"
    }
}

function Write-ProvenanceFiles {
    $manifestFiles = @($sourceFiles.Values | Sort-Object {
        [string]$_.absolute_path })
    $manifestTrees = @($sourceTrees.Values | Sort-Object {
        [string]$_.absolute_path } | ForEach-Object {
        [ordered]@{
            absolute_path = $_.absolute_path
            repository_relative_path = $_.repository_relative_path
            member_count = @($_.member_paths).Count
            member_paths = @($_.member_paths)
            roles = @($_.roles)
        }
    })
    [ordered]@{
        schema_version = "ternarycore-source-manifest-1.0"
        captured_utc = (Get-Date).ToUniversalTime().ToString("o")
        stability_verified = [bool]$sourceStabilityVerified
        files = $manifestFiles
        runtime_trees = $manifestTrees
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sourceManifestPath -Encoding utf8
    $script:sourceManifestSha256 = (
        Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    [ordered]@{
        schema_version = "ternarycore-regression-provenance-1.0"
        run_id = $runId
        repository = $repo
        git_start = $gitStart
        git_final = $gitFinal
        git_porcelain_changed = (
            [string]$gitStart.porcelain_v1 -cne [string]$gitFinal.porcelain_v1)
        environment_lock = $environmentLockRecord
        tools = @($toolFiles.Values)
        source_manifest = [ordered]@{
            path = $sourceManifestPath
            sha256 = $sourceManifestSha256
            stability_verified = [bool]$sourceStabilityVerified
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $provenancePath -Encoding utf8
    $script:provenanceSha256 = (
        Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

$runnerPath = [IO.Path]::GetFullPath($PSCommandPath)

Register-SourceFile -Path $runnerPath -Role "regression_runner"
Register-SourceFile -Path $environmentLockPath -Role "environment_lock"
$environmentLockRecord = New-Sha256Record -Path $environmentLockPath
Register-ToolFile -Name "iverilog" -Path $iverilog
Register-ToolFile -Name "vvp" -Path $vvp
Register-ToolFile -Name "git" -Path $gitExecutable
$powerShellHost = (Get-Process -Id $PID).Path
if (-not [string]::IsNullOrWhiteSpace($powerShellHost)) {
    Register-ToolFile -Name "powershell_host" -Path $powerShellHost
}
if (-not $SkipPython) {
    Register-ToolFile -Name "python_launcher" -Path $PythonExecutable
    $pythonProbeLines = @(
        & $PythonExecutable @PythonArguments -c `
            "import os,sys; print(os.path.realpath(sys.executable))" 2>&1 |
            ForEach-Object { "$_" })
    $pythonProbeExitCode = $LASTEXITCODE
    if ($null -eq $pythonProbeExitCode) {
        $pythonProbeExitCode = 0
    }
    if ([int]$pythonProbeExitCode -ne 0 -or $pythonProbeLines.Count -eq 0) {
        throw "Python runtime probe failed with code $pythonProbeExitCode`: $($pythonProbeLines -join ' ')"
    }
    $pythonRuntimeExecutable = [IO.Path]::GetFullPath(
        [string]$pythonProbeLines[$pythonProbeLines.Count - 1])
    Register-ToolFile -Name "python_runtime" -Path $pythonRuntimeExecutable
}

$gitStart = Get-GitSnapshot
Set-Content -LiteralPath $gitStatusStartPath -Value (
    [string]$gitStart.porcelain_v1) -Encoding utf8 -NoNewline
Write-RunLine "GIT_HEAD $($gitStart.head)"
Write-RunLine "GIT_BRANCH $($gitStart.branch)"
Write-RunLine "GIT_DIRTY $($gitStart.dirty)"
Write-RunLine "ENVIRONMENT_LOCK_SHA256 $($environmentLockRecord.sha256)"

function Invoke-CheckedCommand {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $simTemp,
        [string]$SuccessPattern = ""
    )

    $displayArguments = @($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join " "
    Write-RunLine "COMMAND ${Label}: $FilePath $displayArguments"
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
        Write-RunLine $line
    }
    $text = $lines -join "`n"
    if ([int]$exitCode -ne 0) {
        throw "$Label exited with code $exitCode"
    }
    if ($text -match $failurePattern) {
        throw "$Label emitted failure text"
    }
    if (-not [string]::IsNullOrWhiteSpace($SuccessPattern) -and
        $text -notmatch $SuccessPattern) {
        throw "$Label did not emit its required success marker"
    }
    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = $text
    }
}

function Invoke-IverilogTest {
    param(
        [string]$Name,
        [string[]]$Defines,
        [string[]]$RelativeFiles,
        [string[]]$RuntimeArgs = @(),
        [string]$PassPattern = $defaultSimulationPassPattern,
        [string]$RuntimeWorkingDirectory = $simTemp
    )
    $output = Join-Path $simTemp $Name
    $arguments = @("-g2012")
    foreach ($define in $Defines) {
        $arguments += "-D$define"
    }
    $arguments += @("-o", $output)
    foreach ($relativeFile in $RelativeFiles) {
        $sourcePath = Join-Path $repo $relativeFile
        Register-SourceFile -Path $sourcePath -Role "iverilog:$Name"
        $arguments += $sourcePath
    }
    foreach ($runtimeArgument in $RuntimeArgs) {
        if ($runtimeArgument -match '^\+GOLDEN_ROOT=(.+)$') {
            Register-SourceTree -Path $Matches[1] -Role "runtime_golden:$Name"
        }
    }
    Invoke-CheckedCommand -Label "$Name compile" -FilePath $iverilog -Arguments $arguments | Out-Null
    $simulationParameters = @{
        Label = "$Name simulation"
        FilePath = $vvp
        Arguments = @($output) + @($RuntimeArgs)
        WorkingDirectory = $RuntimeWorkingDirectory
        SuccessPattern = $PassPattern
    }
    Invoke-CheckedCommand @simulationParameters | Out-Null
    $completedSimulations.Add($Name) | Out-Null
    Write-RunLine "SIM_PASS $Name"
}

$originalPythonUtf8 = [Environment]::GetEnvironmentVariable("PYTHONUTF8", "Process")
$runSucceeded = $false
$caughtFailure = $null

try {
if (-not $KvOnly) {
    Invoke-IverilogTest "sim_mac" @() @(
        "tb/tb_ternary_mac.v", "rtl/ternary_mac.v", "rtl/ternary_weight.v")
    Invoke-IverilogTest "sim_dot" @() @(
        "tb/tb_ternary_dot.v", "rtl/ternary_dot.v", "rtl/ternary_weight.v")
    foreach ($depth in 4, 16, 64) {
        Invoke-IverilogTest "sim_gemm_d$depth" @("DEPTH_VAL=$depth") @(
            "tb/tb_ternary_gemm.v", "rtl/ternary_gemm.v",
            "rtl/ternary_dot.v", "rtl/ternary_weight.v")
        Invoke-IverilogTest "sim_axi_gemm_d$depth" @("DEPTH_VAL=$depth") @(
            "tb/tb_axi_gemm_wrapper.v", "rtl/axi_gemm_wrapper.v",
            "rtl/ternary_gemm.v", "rtl/ternary_dot.v",
            "rtl/ternary_weight.v")
    }
    foreach ($width in 4, 8) {
        Invoke-IverilogTest "sim_weight_bram_d$width" @(
            "ADDR_WIDTH_VAL=$width") @(
            "tb/tb_weight_bram.v", "rtl/weight_bram.v")
    }

    Invoke-IverilogTest "sim_ternary_mac_ext" @() @(
        "tb/tb_ternary_mac_ext.v", "rtl/ternary_mac.v",
        "rtl/ternary_weight.v")
    Invoke-IverilogTest "sim_axi_gemm_gaps" @() @(
        "tb/tb_axi_gemm_gaps.v", "rtl/axi_gemm_wrapper.v",
        "rtl/ternary_gemm.v", "rtl/ternary_dot.v",
        "rtl/ternary_weight.v") -PassPattern (
        '(?im)^\s*ALL GAP TESTS PASSED\s*$')
    Invoke-IverilogTest "sim_gemm_stream" @() @(
        "tb/tb_gemm_stream.v", "rtl/ternary_gemm_stream.v",
        "rtl/ternary_gemm.v", "rtl/ternary_dot.v",
        "rtl/ternary_weight.v") -PassPattern (
        '(?im)^\s*RESULT:\s+ALL\s+[0-9]+\s+COLUMNS\s+CORRECT\b')
    Invoke-IverilogTest "sim_axi_gemm_stream" @() @(
        "tb/tb_axi_gemm_stream.v", "rtl/axi_gemm_stream.v",
        "rtl/weight_bram128.v", "rtl/ternary_gemm.v",
        "rtl/ternary_dot.v", "rtl/ternary_weight.v")
    Invoke-IverilogTest "sim_int8_dot" @() @(
        "tb/tb_int8_dot.v", "rtl/int8_expand.v",
        "rtl/ternary_weight.v")
    Invoke-IverilogTest "sim_int8_gemm" @() @(
        "tb/tb_int8_gemm.v", "rtl/int8_gemm.v", "rtl/int8_dot.v") -PassPattern (
        '(?im)^\s*INT8 baseline:\s+ALL\s+[0-9]+\s+COLUMNS\s+CORRECT\s*$')
    Invoke-IverilogTest "sim_int8_stream" @() @(
        "tb/tb_int8_stream.v", "rtl/axi_gemm_stream.v",
        "rtl/ternary_gemm.v", "rtl/ternary_dot.v",
        "rtl/ternary_weight.v")
    Register-SourceTree -Path (Join-Path $PSScriptRoot "vectors") `
        -Role "runtime_golden:rmsnorm"
    Invoke-IverilogTest "sim_rmsnorm_quant" @() @(
        "tb/tb_rmsnorm_quant.v", "rtl/rmsnorm_quant.v") -RuntimeWorkingDirectory $PSScriptRoot
    Invoke-IverilogTest "sim_rmsnorm_quant_axi" @() @(
        "tb/tb_rmsnorm_quant_axi.v", "rtl/rmsnorm_quant_axi.v",
        "rtl/rmsnorm_quant.v") -RuntimeWorkingDirectory $PSScriptRoot
    Invoke-IverilogTest "sim_weight_bram128_burst" @() @(
        "tb/tb_weight_bram128_burst.v", "rtl/weight_bram128.v")
    Invoke-IverilogTest "sim_weight_bram128_wide" @() @(
        "tb/tb_weight_bram128_wide.v", "rtl/weight_bram128.v")
    Invoke-IverilogTest "sim_zybo_pl_clock" @() @(
        "ZyboZ7/tb/zybo_clock_primitive_stubs.v",
        "ZyboZ7/rtl/zybo_pl_clock.v",
        "ZyboZ7/tb/tb_zybo_pl_clock.v") -PassPattern (
        '(?im)^\s*ZYBO_PL_CLOCK_IVERILOG_PASS\s*$')
}

$kvRtl = @(
    "rtl/kv_addr_gen.v", "rtl/int4_unpack.v", "rtl/kv_dequant.v",
    "rtl/qk_dot.v", "rtl/qk_group_dot.v", "rtl/kv_reader.v",
    "rtl/kv_cache_engine.v")
Invoke-IverilogTest "sim_int4_unpack" @() @(
    "tb/tb_int4_unpack.v", "rtl/int4_unpack.v")
Invoke-IverilogTest "sim_kv_v03_crc32" @() @(
    "tb/tb_kv_v03_crc32.v", "rtl/kv_v03_crc32.v")
Invoke-IverilogTest "sim_kv_v03_page_header" @() @(
    "tb/tb_kv_v03_page_header.v", "rtl/kv_v03_page_header.v")
foreach ($pageAddrWidth in 32, 64) {
    foreach ($pageScaleBits in 12, 16) {
        Invoke-IverilogTest (
            "sim_kv_v03_page128_offset_scheduler_a${pageAddrWidth}_s${pageScaleBits}") @(
            "ADDR_WIDTH_VAL=$pageAddrWidth",
            "SCALE_BITS_VAL=$pageScaleBits") @(
            "tb/tb_kv_v03_page128_offset_scheduler.v",
            "rtl/kv_v03_page128_offset_scheduler.v",
            "rtl/kv_v03_crc32.v") -PassPattern (
            "(?im)^\s*TB PASS: page128 offset scheduler addr_width=$pageAddrWidth scale_bits=$pageScaleBits\s*$")
    }
}
Invoke-IverilogTest "sim_kv_v03_hp64_range_reader" @() @(
    "tb/tb_kv_v03_hp64_range_reader.v",
    "rtl/kv_v03_hp64_range_reader.v") -PassPattern (
    '(?im)^\s*TB PASS: HP64 range reader boundaries/splits/faults/abort\s*$')
foreach ($recordScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_page128_record_validator_s${recordScaleBits}") @(
        "SCALE_BITS_VAL=$recordScaleBits") @(
        "tb/tb_kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page_header.v",
        "rtl/kv_v03_crc32.v",
        "rtl/kv_v03_scale12_reader.v") -PassPattern (
            "(?im)^\s*TB PASS: page128 record validator scale_bits=$recordScaleBits\s*$")
}
foreach ($prefetchScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_page_prefetch_slot_s${prefetchScaleBits}") @(
        "SCALE_BITS_VAL=$prefetchScaleBits") @(
        "tb/tb_kv_v03_page_prefetch_slot.v",
        "rtl/kv_v03_page_prefetch_slot.v",
        "rtl/kv_v03_hp64_range_reader.v",
        "rtl/kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page_header.v",
        "rtl/kv_v03_crc32.v",
        "rtl/kv_v03_scale12_reader.v") -PassPattern (
        "(?m)^KV_V03_PAGE_PREFETCH_SLOT_SCALE${prefetchScaleBits}_PASS\s*$")
}
foreach ($pingpongScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_page_pingpong_s${pingpongScaleBits}") @(
        "SCALE_BITS_VAL=$pingpongScaleBits") @(
        "tb/tb_kv_v03_page_pingpong.v",
        "rtl/kv_v03_page_pingpong.v",
        "rtl/kv_v03_page_prefetch_slot.v",
        "rtl/kv_v03_hp64_range_reader.v",
        "rtl/kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page_header.v",
        "rtl/kv_v03_crc32.v",
        "rtl/kv_v03_scale12_reader.v") -PassPattern (
        "(?m)^KV_V03_PAGE_PINGPONG_SCALE${pingpongScaleBits}_PASS\s*$")
}
foreach ($kvPairScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_kv_page_prefetch_s${kvPairScaleBits}") @(
        "SCALE_BITS_VAL=$kvPairScaleBits") @(
        "tb/tb_kv_v03_kv_page_prefetch.v",
        "rtl/kv_v03_kv_page_prefetch.v",
        "rtl/kv_v03_page_pingpong.v",
        "rtl/kv_v03_page_prefetch_slot.v",
        "rtl/kv_v03_hp64_range_reader.v",
        "rtl/kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page_header.v",
        "rtl/kv_v03_crc32.v",
        "rtl/kv_v03_scale12_reader.v") -PassPattern (
        "(?m)^KV_V03_KV_PAGE_PREFETCH_SCALE${kvPairScaleBits}_PASS\s*$")
}
Invoke-IverilogTest "sim_kv_v03_scale12_reader" @() @(
    "tb/tb_kv_v03_scale12_reader.v", "rtl/kv_v03_scale12_reader.v")
foreach ($decodedPageScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_decoded_page_buffer_s${decodedPageScaleBits}") @(
        "SCALE_BITS_VAL=$decodedPageScaleBits") @(
        "tb/tb_kv_v03_decoded_page_buffer.v",
        "rtl/kv_v03_decoded_page_buffer.v",
        "rtl/kv_v03_symbol_decoder.v",
        "rtl/kv_v03_scale12_reader.v") -PassPattern (
             "(?m)^KV_V03_DECODED_PAGE_BUFFER_SCALE${decodedPageScaleBits}_PASS\s*$")
}
foreach ($typedLaneScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_typed_decode_lane_bank_4x1_s${typedLaneScaleBits}") @(
        "SCALE_BITS_VAL=$typedLaneScaleBits") @(
        "tb/tb_kv_v03_typed_decode_lane_bank_4x1.v",
        "rtl/kv_v03_typed_decode_lane_bank_4x1.v",
        "rtl/kv_v03_symbol_decoder.v") -PassPattern (
            "(?m)^KV_V03_TYPED_DECODE_LANE_BANK_4X1_SCALE${typedLaneScaleBits}_PASS\s*$")
}
$decoderGoldenRoot = (Join-Path $repo (
    "analysis/kv_validation/v0_3/codec/decoder_goldens")).Replace("\", "/")
Invoke-IverilogTest "sim_kv_v03_decoders" @() @(
    "tb/tb_kv_v03_decoders.v", "rtl/kv_v03_symbol_decoder.v",
    "rtl/kv_v03_k4_decoder.v", "rtl/kv_v03_v5_decoder.v") @(
    "+GOLDEN_ROOT=$decoderGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_decoder_cluster_2x2" @() @(
    "tb/tb_kv_v03_decoder_cluster_2x2.v",
    "rtl/kv_v03_symbol_decoder.v",
    "rtl/kv_v03_decoder_cluster_2x2.v") @(
    "+GOLDEN_ROOT=$decoderGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_decoder_cluster_4x1" @() @(
    "tb/tb_kv_v03_decoder_cluster_4x1.v",
    "rtl/kv_v03_symbol_decoder.v",
    "rtl/kv_v03_decoder_cluster_4x1.v") @(
    "+GOLDEN_ROOT=$decoderGoldenRoot")
$softmaxGoldenRoot = (Join-Path $repo (
    "analysis/kv_validation/v0_3/rtl_goldens/softmax")).Replace("\", "/")
Invoke-IverilogTest "sim_kv_v03_reciprocal" @() @(
    "tb/tb_kv_v03_reciprocal.v", "rtl/kv_v03_reciprocal.v") @(
    "+GOLDEN_ROOT=$softmaxGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_score_store" @() @(
    "tb/tb_kv_v03_score_store.v", "rtl/kv_v03_score_store.v")
foreach ($quantizerFractionBits in 8, 11) {
    Invoke-IverilogTest (
        "sim_kv_v03_qk_score_quantizer_f${quantizerFractionBits}") @(
        "SCALE_FRACTION_BITS_VAL=$quantizerFractionBits") @(
        "tb/tb_kv_v03_qk_score_quantizer.v",
        "rtl/kv_v03_qk_score_quantizer.v") -PassPattern (
        "(?m)^TB PASS: KV v0\.3 QK score quantizer scale_fraction_bits=${quantizerFractionBits}\r?$")
}
Invoke-IverilogTest "sim_kv_v03_score_row_commit_guard" @() @(
    "tb/tb_kv_v03_score_row_commit_guard.v",
    "rtl/kv_v03_score_row_commit_guard.v") -PassPattern (
    '(?m)^KV_V03_SCORE_ROW_COMMIT_GUARD_PASS\r?$')
foreach ($rawK4ScaleWidth in 12, 16) {
    Invoke-IverilogTest "sim_kv_v03_raw_k4_qk_engine_s$rawK4ScaleWidth" @(
        "SCALE_WIDTH_VAL=$rawK4ScaleWidth") @(
        "tb/tb_kv_v03_raw_k4_qk_engine.v",
        "rtl/kv_v03_raw_k4_qk_engine.v",
        "rtl/kv_v03_hp64_range_reader.v",
        "rtl/qk_group_dot.v",
        "rtl/kv_v03_qk_score_quantizer.v") -PassPattern (
        "(?m)^KV_V03_RAW_K4_QK_ENGINE_SCALE${rawK4ScaleWidth}_PASS\s*$")
}
foreach ($cannedArithmeticScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_kv_v03_canned_page_arithmetic_s${cannedArithmeticScaleBits}") @(
        "SCALE_BITS_VAL=$cannedArithmeticScaleBits") @(
        "tb/tb_kv_v03_canned_page_arithmetic.v",
        "rtl/kv_v03_canned_page_arithmetic.v",
        "rtl/qk_group_dot.v",
        "rtl/kv_v03_qk_score_quantizer.v",
        "rtl/kv_v03_score_row_commit_guard.v",
        "rtl/kv_v03_softmax_engine.v",
        "rtl/kv_v03_score_store.v",
        "rtl/kv_v03_exp_lut.v",
        "rtl/kv_v03_reciprocal.v",
        "rtl/kv_v03_softmax.v",
        "rtl/kv_v03_av_accumulator.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_normalizer.v") -PassPattern (
        "(?m)^KV_V03_CANNED_PAGE_ARITHMETIC_SCALE${cannedArithmeticScaleBits}_PASS\s*$")
}
foreach ($cannedPageDiagScaleBits in 12, 16) {
    Invoke-IverilogTest (
        "sim_axi_kvq_canned_page_diag_s${cannedPageDiagScaleBits}") @(
        "SCALE_BITS_VAL=$cannedPageDiagScaleBits") @(
        "tb/tb_axi_kvq_canned_page_diag.v",
        "rtl/axi_kvq_canned_page_diag.v",
        "rtl/kv_v03_typed_decode_lane_bank_4x1.v",
        "rtl/kv_v03_symbol_decoder.v",
        "rtl/kv_v03_scale12_reader.v",
        "rtl/kv_v03_page128_record_validator.v",
        "rtl/kv_v03_page_header.v",
        "rtl/kv_v03_crc32.v",
        "rtl/kv_v03_canned_page_arithmetic.v",
        "rtl/qk_group_dot.v",
        "rtl/kv_v03_qk_score_quantizer.v",
        "rtl/kv_v03_score_row_commit_guard.v",
        "rtl/kv_v03_softmax_engine.v",
        "rtl/kv_v03_score_store.v",
        "rtl/kv_v03_exp_lut.v",
        "rtl/kv_v03_reciprocal.v",
        "rtl/kv_v03_softmax.v",
        "rtl/kv_v03_av_accumulator.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_normalizer.v") -PassPattern (
        "(?m)^AXI_KVQ_CANNED_PAGE_DIAG_SCALE${cannedPageDiagScaleBits}_PASS\s*$")
}
Invoke-IverilogTest "sim_kv_v03_softmax" @() @(
    "tb/tb_kv_v03_softmax.v", "rtl/kv_v03_softmax_engine.v",
    "rtl/kv_v03_score_store.v",
    "rtl/kv_v03_exp_lut.v", "rtl/kv_v03_reciprocal.v",
    "rtl/kv_v03_softmax.v") @(
    "+GOLDEN_ROOT=$softmaxGoldenRoot")
$avGoldenRoot = (Join-Path $repo (
    "analysis/kv_validation/v0_3/rtl_goldens/av")).Replace("\", "/")
Invoke-IverilogTest "sim_kv_v03_v5_weight_mul" @() @(
    "tb/tb_kv_v03_v5_weight_mul.v", "rtl/kv_v03_v5_weight_mul.v")
foreach ($avMultStyle in 0, 1, 2) {
    Invoke-IverilogTest "sim_kv_v03_av_style$avMultStyle" @(
        "MULT_STYLE_VAL=$avMultStyle") @(
        "tb/tb_kv_v03_av_accumulator.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_accumulator.v") @(
        "+GOLDEN_ROOT=$avGoldenRoot")
}
Invoke-IverilogTest "sim_kv_v03_av_scale16_style2" @(
    "MULT_STYLE_VAL=2", "SCALE_WIDTH_VAL=16") @(
    "tb/tb_kv_v03_av_accumulator.v",
    "rtl/kv_v03_v5_weight_mul.v",
    "rtl/kv_v03_av_accumulator.v") @(
    "+GOLDEN_ROOT=$avGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_av_normalizer" @() @(
    "tb/tb_kv_v03_av_normalizer.v",
    "rtl/kv_v03_av_normalizer.v") -PassPattern (
    '(?im)^\s*TB PASS: KV v0.3 AV normalizer F12 round-even saturation\s*$')
foreach ($pipelineScaleWidth in 12, 16) {
    Invoke-IverilogTest "sim_kv_v03_softmax_av_pipeline_s$pipelineScaleWidth" @(
        "SCALE_WIDTH_VAL=$pipelineScaleWidth") @(
        "tb/tb_kv_v03_softmax_av_pipeline.v",
        "rtl/kv_v03_softmax_av_pipeline.v",
        "rtl/kv_v03_softmax_engine.v",
        "rtl/kv_v03_softmax.v",
        "rtl/kv_v03_score_store.v",
        "rtl/kv_v03_exp_lut.v",
        "rtl/kv_v03_reciprocal.v",
        "rtl/kv_v03_raw_v5_av_engine.v",
        "rtl/kv_v03_raw_v5_axi_reader.v",
        "rtl/kv_v03_av_accumulator.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_normalizer.v") -PassPattern (
        "(?im)^\s*TB PASS: KV v0.3 score-softmax-rawV-AV-normalized pipeline scale_width=$pipelineScaleWidth\s*$")
}
foreach ($attentionScaleWidth in 12, 16) {
    Invoke-IverilogTest "sim_axi_kvq_raw_attention_diag_s$attentionScaleWidth" @(
        "SCALE_WIDTH_VAL=$attentionScaleWidth",
        "AXI_DATA_WIDTH_VAL=64") @(
        "tb/tb_axi_kvq_raw_attention_diag.v",
        "rtl/axi_kvq_raw_attention_diag.v",
        "rtl/kv_v03_softmax_av_pipeline.v",
        "rtl/kv_v03_softmax_engine.v",
        "rtl/kv_v03_softmax.v",
        "rtl/kv_v03_score_store.v",
        "rtl/kv_v03_exp_lut.v",
        "rtl/kv_v03_reciprocal.v",
        "rtl/kv_v03_raw_v5_av_engine.v",
        "rtl/kv_v03_raw_v5_axi_reader.v",
        "rtl/kv_v03_av_accumulator.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_normalizer.v") -PassPattern (
        "(?im)^\s*TB PASS: AXI KVQ raw-attention diagnostic scale_width=$attentionScaleWidth axi_width=64\s*$")
}
foreach ($rawFullScaleWidth in 12, 16) {
    foreach ($rawFullAxiWidth in 64, 128) {
        Invoke-IverilogTest (
            "sim_axi_kvq_raw_full_diag_s${rawFullScaleWidth}_a${rawFullAxiWidth}") @(
            "SCALE_WIDTH_VAL=$rawFullScaleWidth",
            "AXI_DATA_WIDTH_VAL=$rawFullAxiWidth") @(
            "tb/tb_axi_kvq_raw_full_diag.v",
            "rtl/axi_kvq_raw_full_diag.v",
            "rtl/kv_v03_raw_k4_qk_engine.v",
            "rtl/kv_v03_hp64_range_reader.v",
            "rtl/qk_group_dot.v",
            "rtl/kv_v03_qk_score_quantizer.v",
            "rtl/kv_v03_score_row_commit_guard.v",
            "rtl/kv_v03_softmax_av_pipeline.v",
            "rtl/kv_v03_softmax_engine.v",
            "rtl/kv_v03_softmax.v",
            "rtl/kv_v03_score_store.v",
            "rtl/kv_v03_exp_lut.v",
            "rtl/kv_v03_reciprocal.v",
            "rtl/kv_v03_raw_v5_av_engine.v",
            "rtl/kv_v03_raw_v5_axi_reader.v",
            "rtl/kv_v03_av_accumulator.v",
            "rtl/kv_v03_v5_weight_mul.v",
            "rtl/kv_v03_av_normalizer.v") -PassPattern (
            "(?m)^AXI_KVQ_RAW_FULL_DIAG_SCALE${rawFullScaleWidth}_AXI${rawFullAxiWidth}_PASS\s*$")
    }
}
foreach ($avAxiWidth in 64, 128) {
    Invoke-IverilogTest "sim_axi_v5_av_diag_$avAxiWidth" @(
        "AXI_DATA_WIDTH_VAL=$avAxiWidth") @(
        "tb/tb_axi_v5_av_diag.v",
        "rtl/axi_v5_av_diag.v",
        "rtl/kv_v03_raw_v5_av_engine.v",
        "rtl/kv_v03_raw_v5_axi_reader.v",
        "rtl/kv_v03_v5_weight_mul.v",
        "rtl/kv_v03_av_accumulator.v") @(
        "+GOLDEN_ROOT=$avGoldenRoot") -PassPattern (
        '(?m)^TB PASS: AXI raw-V5 AV diagnostic\r?$')
}
Invoke-IverilogTest "sim_kv_dequant" @() @(
    "tb/tb_kv_dequant.v", "rtl/kv_dequant.v")
Invoke-IverilogTest "sim_qk_dot" @() @(
    "tb/tb_qk_dot.v", "rtl/qk_dot.v")
$goldenRoot = Join-Path $repo (
    "analysis/kv_validation/real_model/qk_profile_golden_v0_2")
Register-SourceTree -Path $goldenRoot -Role "runtime_golden:qk_group_dot"
foreach ($qkProfile in @(
    @{Name="regular4"; Width=4}, @{Name="accurate5"; Width=5})) {
    $profileRoot = (Join-Path $goldenRoot $qkProfile.Name).Replace("\", "/")
    foreach ($multStyle in 0, 2) {
        Invoke-IverilogTest (
            "sim_qk_group_dot_$($qkProfile.Name)_style$multStyle") @(
            "K_WIDTH_VAL=$($qkProfile.Width)",
            "MULT_STYLE_VAL=$multStyle") @(
            "tb/tb_qk_group_dot.v", "rtl/qk_group_dot.v") @(
            "+GOLDEN_ROOT=$profileRoot")
    }
}
Invoke-IverilogTest "sim_kv_cache_engine" @() @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_64" @(
    "AXI_DATA_WIDTH_VAL=64") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_256" @(
    "AXI_DATA_WIDTH_VAL=256") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_hd128" @(
    "HEAD_DIM_VAL=128") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_hd128_64" @(
    "HEAD_DIM_VAL=128", "AXI_DATA_WIDTH_VAL=64") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_hd128_256" @(
    "HEAD_DIM_VAL=128", "AXI_DATA_WIDTH_VAL=256") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache" @() @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache_64" @(
    "AXI_DATA_WIDTH_VAL=64") @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache_hd128" @(
    "HEAD_DIM_VAL=128") @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache_hd128_64" @(
    "HEAD_DIM_VAL=128", "AXI_DATA_WIDTH_VAL=64") @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)

if (-not $SkipPython) {
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "Process")
    $pythonTests = @(
        @{ Path = "verify/verify_mac.py"; Pass = '(?im)^\s*ALL TESTS PASSED\s*$'; RuntimeFiles = @(); RuntimeTrees = @() },
        @{ Path = "verify/verify_dot.py"; Pass = '(?im)^\s*ALL TESTS PASSED\s*$'; RuntimeFiles = @(); RuntimeTrees = @() },
        @{ Path = "verify/verify_gemm.py"; Pass = '(?im)^\s*ALL TESTS PASSED\s*$'; RuntimeFiles = @(); RuntimeTrees = @() },
        @{ Path = "verify/verify_kv_int4.py"; Pass = '(?im)^\s*KV INT4 reference PASS:'; RuntimeFiles = @(); RuntimeTrees = @() },
        @{ Path = "verify/verify_kv_quant.py"; Pass = '(?im)^\s*KV quantization reference PASS\s*$'; RuntimeFiles = @("verify/kv_quant_reference.py"); RuntimeTrees = @() },
        @{ Path = "verify/verify_kv_analysis_artifacts.py"; Pass = '(?im)^\s*KV v0\.2 analysis artifacts PASS\s*$'; RuntimeFiles = @(); RuntimeTrees = @("docs/runs") })
    foreach ($test in $pythonTests) {
        $testRelativePath = [string]$test.Path
        $testPath = Join-Path $PSScriptRoot $testRelativePath
        Register-SourceFile -Path $testPath -Role "python:$testRelativePath"
        foreach ($runtimeFile in @($test.RuntimeFiles)) {
            Register-SourceFile -Path (Join-Path $PSScriptRoot $runtimeFile) `
                -Role "python_runtime:$testRelativePath"
        }
        foreach ($runtimeTree in @($test.RuntimeTrees)) {
            Register-SourceTree -Path (Join-Path $repo $runtimeTree) `
                -Role "python_runtime:$testRelativePath"
        }
        Invoke-CheckedCommand -Label $testRelativePath -FilePath $PythonExecutable -Arguments (
            @($PythonArguments) + @($testPath)) -SuccessPattern ([string]$test.Pass) | Out-Null
        $completedPythonTests.Add($testRelativePath) | Out-Null
        Write-RunLine "PY_VERIFY_PASS $testRelativePath"
    }
}

$runSucceeded = $true
}
catch {
    $caughtFailure = $_
    Write-RunLine "FULL_WINDOWS_REGRESSION_FAILED $($_.Exception.Message)"
}
finally {
    if ($null -eq $originalPythonUtf8) {
        Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "PYTHONUTF8", $originalPythonUtf8, "Process")
    }

    if ($runSucceeded -and $null -eq $caughtFailure) {
        try {
            Assert-ProvenanceStable
            $sourceStabilityVerified = $true
            Write-RunLine "SOURCE_PROVENANCE_STABLE"
        }
        catch {
            $caughtFailure = $_
            $runSucceeded = $false
            Write-RunLine "REGRESSION_PROVENANCE_FAILED $($_.Exception.Message)"
        }
    }
    if ($null -eq $gitFinal) {
        try {
            $gitFinal = Get-GitSnapshot
        }
        catch {
            if ($null -eq $caughtFailure) {
                $caughtFailure = $_
            }
            $runSucceeded = $false
            $gitFinal = [ordered]@{
                captured_utc = (Get-Date).ToUniversalTime().ToString("o")
                head = $null
                branch = $null
                detached = $null
                dirty = $null
                porcelain_v1 = ""
                error = $_.Exception.Message
            }
            Write-RunLine "GIT_FINAL_CAPTURE_FAILED $($_.Exception.Message)"
        }
    }
    Set-Content -LiteralPath $gitStatusFinalPath -Value (
        [string]$gitFinal.porcelain_v1) -Encoding utf8 -NoNewline
    try {
        Write-ProvenanceFiles
    }
    catch {
        if ($null -eq $caughtFailure) {
            $caughtFailure = $_
        }
        $runSucceeded = $false
        Write-RunLine "PROVENANCE_WRITE_FAILED $($_.Exception.Message)"
    }

    $workRetained = $true
    if ($runSucceeded -and -not $KeepWork) {
        try {
            Remove-SafeOwnedRunDirectory -Target $runWorkDirectory `
                -ExpectedParent $workCategory -ExpectedLeaf $runId `
                -OwnerToken $runOwnerToken
            $workRetained = $false
        }
        catch {
            if ($null -eq $caughtFailure) {
                $caughtFailure = $_
            }
            $runSucceeded = $false
            Write-RunLine "REGRESSION_CLEANUP_FAILED $($_.Exception.Message)"
        }
    }

    $failureMessage = $null
    if ($null -ne $caughtFailure) {
        $failureMessage = $caughtFailure.Exception.Message
    }
    [ordered]@{
        schema_version = "ternarycore-windows-regression-1.1"
        started_run_id = $runId
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        repository = $repo
        git_head = $gitStart.head
        git_branch = $gitStart.branch
        git_dirty = [bool]$gitStart.dirty
        git_status_start = $gitStatusStartPath
        git_status_final = $gitStatusFinalPath
        passed = ($runSucceeded -and $null -eq $caughtFailure)
        failure = $failureMessage
        kv_only = [bool]$KvOnly
        skip_python = [bool]$SkipPython
        iverilog = $iverilog
        vvp = $vvp
        python_executable = $PythonExecutable
        python_arguments = @($PythonArguments)
        simulations = @($completedSimulations)
        python_tests = @($completedPythonTests)
        work_directory = $runWorkDirectory
        work_retained = $workRetained
        evidence_directory = $runEvidenceDirectory
        log = $logPath
        source_manifest = $sourceManifestPath
        source_manifest_sha256 = $sourceManifestSha256
        source_stability_verified = [bool]$sourceStabilityVerified
        provenance = $provenancePath
        provenance_sha256 = $provenanceSha256
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}

if ($null -ne $caughtFailure) {
    throw $caughtFailure
}

if ($workRetained) {
    Write-RunLine "REGRESSION_WORK $runWorkDirectory"
}
Write-RunLine "REGRESSION_EVIDENCE $runEvidenceDirectory"
Write-RunLine "FULL_WINDOWS_REGRESSION_PASS"
