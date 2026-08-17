param(
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDirectory "..\..\..")).Path
$workspaceRoot = Split-Path -Parent $repositoryRoot
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspaceRoot "kv-v0.3-resume-$timestamp"
}

$resolvedParent = (Resolve-Path -LiteralPath (Split-Path -Parent $OutputDirectory)).Path
$stagingRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $stagingRoot.StartsWith($resolvedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing staging path outside the requested parent: $stagingRoot"
}
if (Test-Path -LiteralPath $stagingRoot) {
    throw "Output directory already exists: $stagingRoot"
}

New-Item -ItemType Directory -Path $stagingRoot | Out-Null

$metadataDirectory = Join-Path $stagingRoot "metadata"
$repositorySnapshot = Join-Path $stagingRoot "repository_snapshot"
$completedRunsRoot = Join-Path $stagingRoot "completed_runs"
New-Item -ItemType Directory -Path $metadataDirectory | Out-Null
New-Item -ItemType Directory -Path $repositorySnapshot | Out-Null
New-Item -ItemType Directory -Path $completedRunsRoot | Out-Null

(& git -C $repositoryRoot status --short --branch) | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "git-status.txt")
(& git -C $repositoryRoot rev-parse HEAD) | Set-Content -Encoding ascii (Join-Path $metadataDirectory "git-head.txt")
(& git -C $repositoryRoot branch --show-current) | Set-Content -Encoding ascii (Join-Path $metadataDirectory "git-branch.txt")
(& git -C $repositoryRoot diff --binary HEAD) | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "working-tree.patch")
(& git -C $repositoryRoot ls-files --others --exclude-standard) | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "untracked-files.txt")

$bundlePath = Join-Path $repositorySnapshot "ternarycore-v0.3.bundle"
& git -C $repositoryRoot bundle create $bundlePath HEAD "codex/kv-v0.3-todo"
if ($LASTEXITCODE -ne 0) {
    throw "git bundle creation failed"
}
& git -C $repositoryRoot bundle verify $bundlePath | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "git-bundle-verify.txt")
if ($LASTEXITCODE -ne 0) {
    throw "git bundle verification failed"
}

$v03Root = Join-Path $repositoryRoot "analysis\kv_validation\v0_3"
$staticDestination = Join-Path $repositorySnapshot "analysis\kv_validation\v0_3"
New-Item -ItemType Directory -Path $staticDestination -Force | Out-Null
Get-ChildItem -LiteralPath $v03Root -File | Copy-Item -Destination $staticDestination
foreach ($staticDirectoryName in @("codec", "reports")) {
    $source = Join-Path $v03Root $staticDirectoryName
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $staticDestination -Recurse
    }
}

$scriptsDestination = Join-Path $repositorySnapshot "analysis\kv_validation\scripts"
New-Item -ItemType Directory -Path $scriptsDestination -Force | Out-Null
Get-ChildItem -LiteralPath $scriptDirectory -File -Filter "*v0_3*" | Copy-Item -Destination $scriptsDestination
Copy-Item -LiteralPath (Join-Path $scriptDirectory "packed5_page_codec.py") -Destination $scriptsDestination
Copy-Item -LiteralPath (Join-Path $scriptDirectory "bitnet_streaming_reference.py") -Destination $scriptsDestination

$runRoot = Join-Path $v03Root "results\gate_a"
$completedRunRecords = @()
if (Test-Path -LiteralPath $runRoot) {
    foreach ($runFile in Get-ChildItem -LiteralPath $runRoot -Recurse -File -Filter "run.json") {
        $profileDirectory = $runFile.Directory.FullName
        if (-not $profileDirectory.StartsWith($runRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Completed profile is outside the Gate A root: $profileDirectory"
        }
        $relativeProfile = $profileDirectory.Substring($runRoot.Length).TrimStart("\")
        $destination = Join-Path $completedRunsRoot $relativeProfile
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $profileDirectory -Destination $destination -Recurse
        $completedRunRecords += [ordered]@{
            relative_profile = $relativeProfile
            run_json_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $runFile.FullName).Hash
        }
    }

    $logRoot = Join-Path $runRoot "logs"
    if (Test-Path -LiteralPath $logRoot) {
        Copy-Item -LiteralPath $logRoot -Destination (Join-Path $stagingRoot "gate_a_logs") -Recurse
    }
}
$completedRunRecords | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "completed-runs.json")

$compactResultsRoot = Join-Path $stagingRoot "compact_results"
New-Item -ItemType Directory -Path $compactResultsRoot | Out-Null
if (Test-Path -LiteralPath $runRoot) {
    $gateSummaryDestination = Join-Path $compactResultsRoot "gate_a"
    New-Item -ItemType Directory -Path $gateSummaryDestination | Out-Null
    Get-ChildItem -LiteralPath $runRoot -File | Copy-Item -Destination $gateSummaryDestination
}
foreach ($resultDirectoryName in @("fixedpoint", "schedule", "rtl")) {
    $resultDirectory = Join-Path $v03Root "results\$resultDirectoryName"
    if (Test-Path -LiteralPath $resultDirectory) {
        Copy-Item -LiteralPath $resultDirectory -Destination $compactResultsRoot -Recurse
    }
}

# Routed implementation reports and checkpoints are intentionally ignored by
# Git because they are large and tool-generated.  Preserve them beside the
# compact numerical evidence so the resource/timing conclusions can be audited
# after moving environments.
$implementationEvidenceRoot = Join-Path $stagingRoot "implementation_evidence"
$vivadoEvidence = Join-Path $repositoryRoot (
    "analysis\kv_validation\hardware_estimates\vivado_v0_3_blocks_2026_1")
if (Test-Path -LiteralPath $vivadoEvidence) {
    New-Item -ItemType Directory -Path $implementationEvidenceRoot -Force | Out-Null
    Copy-Item -LiteralPath $vivadoEvidence -Destination $implementationEvidenceRoot -Recurse
}
foreach ($toolLogName in @("vivado.log", "vivado.jou", "clockInfo.txt")) {
    $toolLog = Join-Path $repositoryRoot $toolLogName
    if (Test-Path -LiteralPath $toolLog) {
        New-Item -ItemType Directory -Path $implementationEvidenceRoot -Force | Out-Null
        Copy-Item -LiteralPath $toolLog -Destination $implementationEvidenceRoot
    }
}

$referenceBaseRoot = Join-Path $stagingRoot "reference_base_runs"
foreach ($promptId in @("engineering", "observatory")) {
    $referenceBase = Join-Path $repositoryRoot "analysis\kv_validation\real_model\end_to_end_injection\$promptId\BASE_FP"
    if (-not (Test-Path -LiteralPath (Join-Path $referenceBase "run.json"))) {
        throw "Required imported context-128 BASE_FP reference is missing: $referenceBase"
    }
    $referenceDestination = Join-Path $referenceBaseRoot "$promptId\BASE_FP"
    New-Item -ItemType Directory -Path (Split-Path -Parent $referenceDestination) -Force | Out-Null
    Copy-Item -LiteralPath $referenceBase -Destination $referenceDestination -Recurse
}

foreach ($externalName in @(
    "kv-cache-v0.3-theory-closure-handoff-20260816.zip",
    "kv-v0.3-execution-request-20260816.md"
)) {
    $externalPath = Join-Path $workspaceRoot $externalName
    if (Test-Path -LiteralPath $externalPath) {
        Copy-Item -LiteralPath $externalPath -Destination $repositorySnapshot
    }
}

$processSnapshot = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match "python|vivado|iverilog" } |
    Select-Object ProcessId, Name, CreationDate, WorkingSetSize, CommandLine
$processSnapshot | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $metadataDirectory "active-processes.json")

$manifestPath = Join-Path $stagingRoot "SHA256SUMS.json"
$manifestEntries = Get-ChildItem -LiteralPath $stagingRoot -Recurse -File |
    Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($stagingRoot.Length).TrimStart("\").Replace("\", "/")
            bytes = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
    }
$manifestEntries | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $manifestPath

$zipPath = "$stagingRoot.zip"
Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipReader = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $zipEntries = $zipReader.Entries.Count
    $manifestEntry = $zipReader.Entries |
        Where-Object { $_.FullName -match '(^|[\\/])SHA256SUMS\.json$' }
    if ($null -eq $manifestEntry) {
        throw "Archive verification failed: SHA256SUMS.json is absent"
    }
}
finally {
    $zipReader.Dispose()
}

[ordered]@{
    staging_directory = $stagingRoot
    archive = $zipPath
    archive_bytes = (Get-Item -LiteralPath $zipPath).Length
    archive_sha256 = $zipHash
    archive_entries = $zipEntries
    completed_profiles = $completedRunRecords.Count
} | ConvertTo-Json -Depth 4
