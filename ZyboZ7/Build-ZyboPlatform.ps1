[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $true, Position = 1)]
    [string] $EvidenceDirectory,

    [Parameter(Position = 2)]
    [ValidateSet('75', '81.25')]
    [string] $ClockMHz = '75',

    [ValidateRange(1, 32)]
    [int] $Jobs = 4,

    [ValidateSet(12, 16)]
    [int] $RawFullScaleWidth = 12,

    [ValidateSet(64, 128)]
    [int] $RawFullAxiWidth = 64,

    [ValidateSet('BALANCED', 'LUT_RELIEF')]
    [string] $RawFullProfile = 'BALANCED',

    [ValidateSet(12, 16)]
    [int] $CannedPageScaleBits = 12,

    [ValidateSet(2, 4)]
    [int] $CannedPageDecodeLanes = 2,

    [ValidateSet('BALANCED', 'LUT_RELIEF')]
    [string] $CannedPageProfile = 'BALANCED',

    [string] $VivadoExecutable = 'D:\xilinx\2025.1\Vivado\bin\vivado.bat',

    [ValidateRange(60, 21600)]
    [int] $TimeoutSeconds = 7200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Build-ZyboPlatform.ps1 requires PowerShell 7 or newer (pwsh.exe) for safe path and process-tree handling.'
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if (-not $item.PSIsContainer -and $item.Length -gt 0) {
        return [IO.Path]::GetFullPath($item.FullName)
    }
    throw "$Label must be a nonempty regular file: $resolved"
}

function Resolve-RequiredDirectory {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer) {
        return [IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
    }
    throw "$Label must be a directory: $resolved"
}

function Resolve-NewDirectoryPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Label,
        [Parameter(Mandatory = $true)] [int] $MaximumLength
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be an absolute path: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root.TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label cannot be a drive root: $full"
    }
    if (-not [string]::Equals($root, 'D:\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be on D: to protect the small system drive: $full"
    }
    if ($full.Length -gt $MaximumLength) {
        throw "$Label exceeds $MaximumLength characters; choose a shorter D: path: $full"
    }
    if (Test-Path -LiteralPath $full) {
        throw "$Label must be a brand-new path: $full"
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Label parent must already exist: $parent"
    }
    $ancestor = Get-Item -LiteralPath $parent -Force
    while ($null -ne $ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label parent chain contains a reparse point: $($ancestor.FullName)"
        }
        $ancestor = $ancestor.Parent
    }
    return $full
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)] [string] $Candidate,
        [Parameter(Mandatory = $true)] [string] $Parent
    )

    $relative = [IO.Path]::GetRelativePath(
        [IO.Path]::GetFullPath($Parent),
        [IO.Path]::GetFullPath($Candidate)
    )
    if ($relative -eq '.') {
        return $true
    }
    return (-not [IO.Path]::IsPathRooted($relative)) -and
        ($relative -ne '..') -and
        (-not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)"))
}

function Test-PathsOverlap {
    param(
        [Parameter(Mandatory = $true)] [string] $Left,
        [Parameter(Mandatory = $true)] [string] $Right
    )

    return (Test-PathWithin -Candidate $Left -Parent $Right) -or
        (Test-PathWithin -Candidate $Right -Parent $Left)
}

function Find-GitExecutable {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'Git is not on PATH and LOCALAPPDATA is unavailable'
    }
    $candidates = @(Get-ChildItem -Path (
        Join-Path $env:LOCALAPPDATA 'GitHubDesktop\app-*\resources\app\git\cmd\git.exe'
    ) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        throw 'Git is not on PATH and GitHub Desktop bundled Git was not found'
    }
    return $candidates[0].FullName
}

function Assert-CmdSafePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    if ($Path -match '[\r\n"&|<>^%!()]') {
        throw "$Label contains a character that cannot be passed safely through cmd.exe: $Path"
    }
}

function Get-FileIdentity {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $item = Get-Item -LiteralPath $Path -Force
    return [ordered]@{
        path = [IO.Path]::GetFullPath($item.FullName)
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([Convert]::ToHexString($algorithm.ComputeHash($bytes))).ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-AllowlistedCriticalWarning {
    param(
        [Parameter(Mandatory = $true)] [string] $Line,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $Contract
    )

    if ($Line -cnotmatch (
        '^CRITICAL WARNING: \[([^\]]+)\]\s+' +
        'Parameter\s*:\s*(\S+)\s+has negative value\s+(\S+)\s+\.\s+(.+?)\s*$'
    )) {
        return $null
    }
    $identifier = $Matches[1]
    $parameter = $Matches[2]
    $value = $Matches[3]
    $message = $Matches[4]
    $parameterIndex = $null
    if ($parameter -cmatch '_([0-9]+)$') {
        $parameterIndex = [int]$Matches[1]
    }
    if (-not $Contract.Contains($identifier)) {
        return $null
    }
    $expected = $Contract[$identifier]
    if ($parameter -cne $expected.parameter -or
        $null -eq $parameterIndex -or
        $parameterIndex -ne $expected.parameter_index -or
        $value -cne $expected.value -or
        $message -cne $expected.message) {
        return $null
    }
    return [pscustomobject][ordered]@{
        id = $identifier
        parameter = $parameter
        parameter_index = $parameterIndex
        value = $value
        message = $message
    }
}

function Get-VivadoMessageScan {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Files,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $AllowedCriticalWarnings
    )

    $allowlisted = [Collections.Generic.List[object]]::new()
    $unexpected = [Collections.Generic.List[object]]::new()
    $fatalMessages = [Collections.Generic.List[object]]::new()
    $fileIdentities = [Collections.Generic.List[object]]::new()
    $ordinaryWarningCount = 0

    foreach ($path in @($Files | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $resolved = [IO.Path]::GetFullPath((Get-Item -LiteralPath $path -Force).FullName)
        $fileIdentity = Get-FileIdentity -Path $resolved
        $fileIdentities.Add([pscustomobject]$fileIdentity)
        $lines = @(Get-Content -LiteralPath $resolved -ErrorAction Stop)
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            if ($line -cmatch '^WARNING:') {
                $ordinaryWarningCount++
            }
            if ($line -cmatch 'CRITICAL WARNING:') {
                $identifier = $null
                if ($line -cmatch 'CRITICAL WARNING:\s*\[([^\]]+)\]') {
                    $identifier = $Matches[1]
                }
                $matchedWarning = Get-AllowlistedCriticalWarning `
                    -Line $line -Contract $AllowedCriticalWarnings
                $occurrence = [pscustomobject][ordered]@{
                    file = $resolved
                    file_sha256 = $fileIdentity.sha256
                    line_number = $index + 1
                    id = $identifier
                    parameter = if ($null -ne $matchedWarning) { $matchedWarning.parameter } else { $null }
                    parameter_index = if ($null -ne $matchedWarning) { $matchedWarning.parameter_index } else { $null }
                    value = if ($null -ne $matchedWarning) { $matchedWarning.value } else { $null }
                    message = if ($null -ne $matchedWarning) { $matchedWarning.message } else { $null }
                    line = $line
                    line_sha256 = Get-StringSha256 -Value $line
                }
                if ($null -ne $matchedWarning) {
                    $allowlisted.Add($occurrence)
                } else {
                    $unexpected.Add($occurrence)
                }
            }
            if ($line -cmatch '^(?:ERROR|FATAL):') {
                $fatalMessages.Add([pscustomobject][ordered]@{
                    file = $resolved
                    file_sha256 = $fileIdentity.sha256
                    line_number = $index + 1
                    line = $line
                    line_sha256 = Get-StringSha256 -Value $line
                })
            }
        }
    }

    return [pscustomobject][ordered]@{
        scanned_files = @($fileIdentities)
        ordinary_warning_count = $ordinaryWarningCount
        allowlisted_critical_warning_occurrences = @($allowlisted)
        unexpected_critical_warning_occurrences = @($unexpected)
        fatal_message_occurrences = @($fatalMessages)
    }
}

function Invoke-VivadoStage {
    param(
        [Parameter(Mandatory = $true)] [string] $StageName,
        [Parameter(Mandatory = $true)] [string] $VivadoPath,
        [Parameter(Mandatory = $true)] [string] $TclSource,
        [Parameter(Mandatory = $true)] [string[]] $TclArguments,
        [Parameter(Mandatory = $true)] [string] $ExpectedPassToken,
        [Parameter(Mandatory = $true)] [string] $EvidencePath,
        [Parameter(Mandatory = $true)] [string] $TemporaryPath,
        [Parameter(Mandatory = $true)] [string] $GeneratedOutputPath,
        [Parameter(Mandatory = $true)] [string] $GitDirectory,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $AllowedCriticalWarnings,
        [Parameter(Mandatory = $true)] [int] $StageTimeoutSeconds
    )

    $vivadoLog = Join-Path $EvidencePath "$StageName.vivado.log"
    $vivadoJournal = Join-Path $EvidencePath "$StageName.vivado.jou"
    $stdoutLog = Join-Path $EvidencePath "$StageName.stdout.log"
    $stderrLog = Join-Path $EvidencePath "$StageName.stderr.log"
    $commandArguments = @($TclArguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    $commandLine = (
        'call "{0}" -mode batch -log "{1}" -journal "{2}" -source "{3}" -tclargs {4}' -f
            $VivadoPath, $vivadoLog, $vivadoJournal, $TclSource, $commandArguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.WorkingDirectory = $EvidencePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = '/d /s /c "' + $commandLine + '"'
    foreach ($variable in @('TMP', 'TEMP', 'TMPDIR')) {
        $startInfo.Environment[$variable] = $TemporaryPath
    }
    $inheritedPath = [string]$startInfo.Environment['PATH']
    $startInfo.Environment['PATH'] = if ([string]::IsNullOrWhiteSpace($inheritedPath)) {
        $GitDirectory
    } else {
        $GitDirectory + [IO.Path]::PathSeparator + $inheritedPath
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutStream = $null
    $stderrStream = $null
    $stdoutTask = $null
    $stderrTask = $null
    $launchError = $null
    $killError = $null
    $killAttempted = $false
    $timedOut = $false
    $exitCode = $null
    $processId = $null
    $started = $false
    $startedUtc = [DateTime]::UtcNow

    try {
        $stdoutStream = [IO.File]::Open(
            $stdoutLog, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::ReadWrite
        )
        $stderrStream = [IO.File]::Open(
            $stderrLog, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::ReadWrite
        )
        if (-not $process.Start()) {
            throw 'Process.Start returned false'
        }
        $started = $true
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
        if (-not $process.WaitForExit($StageTimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $killAttempted = $true
                $process.Kill($true)
            } catch {
                $killError = $_.Exception.Message
            }
            $null = $process.WaitForExit(30000)
        }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
        }
    } catch {
        $launchError = $_.Exception.Message
    } finally {
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $killAttempted = $true
                    $process.Kill($true)
                    $null = $process.WaitForExit(30000)
                }
            } catch {
                if ($null -eq $killError) {
                    $killError = $_.Exception.Message
                }
            }
        }
        foreach ($task in @($stdoutTask, $stderrTask)) {
            if ($null -ne $task) {
                try {
                    if (-not $task.Wait(30000)) {
                        $launchError = 'Vivado output stream did not close within 30 seconds'
                    }
                } catch {
                    $launchError = "Vivado output capture failed: $($_.Exception.Message)"
                }
            }
        }
        if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
        if ($null -ne $stderrStream) { $stderrStream.Dispose() }
        $process.Dispose()
    }

    $stdoutLines = @(if (Test-Path -LiteralPath $stdoutLog) {
        Get-Content -LiteralPath $stdoutLog
    })
    $stderrLines = @(if (Test-Path -LiteralPath $stderrLog) {
        Get-Content -LiteralPath $stderrLog
    })
    $tokenLines = @($stdoutLines) + @($stderrLines)
    $passTokenCount = @($tokenLines | Where-Object {
        $_ -ceq $ExpectedPassToken
    }).Count
    $failureTokens = @($tokenLines | Where-Object {
        $_ -cmatch '^ZYBO_PLATFORM_(?:CREATE|BUILD)_FAIL(?:$|:)'
    })

    $explicitLogs = @($vivadoLog, $vivadoJournal, $stdoutLog, $stderrLog)
    $generatedLogs = @()
    if (Test-Path -LiteralPath $GeneratedOutputPath -PathType Container) {
        $generatedLogs = @(Get-ChildItem -LiteralPath $GeneratedOutputPath -Recurse -File `
            -ErrorAction Stop | Where-Object { $_.Extension -in @('.log', '.jou') } |
            ForEach-Object { $_.FullName })
    }
    $messageScan = Get-VivadoMessageScan `
        -Files @($explicitLogs + $generatedLogs) `
        -AllowedCriticalWarnings $AllowedCriticalWarnings

    $missingCaptureFiles = @($explicitLogs | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    })
    $emptyRequiredLogs = @(@($vivadoLog, $vivadoJournal, $stdoutLog) | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        (Get-Item -LiteralPath $_ -Force).Length -eq 0
    })
    $success = ($null -eq $launchError) -and (-not $timedOut) -and
        ($null -eq $killError) -and ($exitCode -eq 0) -and
        ($passTokenCount -eq 1) -and ($failureTokens.Count -eq 0) -and
        ($missingCaptureFiles.Count -eq 0) -and ($emptyRequiredLogs.Count -eq 0) -and
        ($messageScan.unexpected_critical_warning_occurrences.Count -eq 0) -and
        ($messageScan.fatal_message_occurrences.Count -eq 0)

    if ($stdoutLines.Count -gt 0) {
        [Console]::Out.WriteLine(($stdoutLines -join [Environment]::NewLine))
    }
    if ($stderrLines.Count -gt 0) {
        [Console]::Error.WriteLine(($stderrLines -join [Environment]::NewLine))
    }

    return [pscustomobject][ordered]@{
        stage = $StageName
        result = if ($success) { 'PASS' } else { 'FAIL' }
        started_utc = $startedUtc.ToString('o')
        ended_utc = [DateTime]::UtcNow.ToString('o')
        timeout_seconds = $StageTimeoutSeconds
        timed_out = $timedOut
        spawned_process_id = $processId
        process_exit_code = $exitCode
        process_tree_kill_attempted = $killAttempted
        exact_pass_token = $ExpectedPassToken
        exact_pass_token_count = $passTokenCount
        failure_tokens = $failureTokens
        launch_error = $launchError
        process_tree_kill_error = $killError
        missing_capture_files = $missingCaptureFiles
        empty_required_logs = $emptyRequiredLogs
        command = [ordered]@{
            executable = $VivadoPath
            source = $TclSource
            tcl_arguments = $TclArguments
            working_directory = $EvidencePath
            temporary_directory = $TemporaryPath
            git_directory_prepended_to_path = $GitDirectory
        }
        logs = [ordered]@{
            vivado_log = $vivadoLog
            vivado_journal = $vivadoJournal
            stdout = $stdoutLog
            stderr = $stderrLog
        }
        message_scan = $messageScan
    }
}

function Get-RequiredArtifactIdentities {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Paths,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $identities = [Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "$Label is absent: $path"
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Length -eq 0) {
            throw "$Label is empty: $path"
        }
        $identities.Add([pscustomobject](Get-FileIdentity -Path $item.FullName))
    }
    return @($identities)
}

$scriptPath = Resolve-RequiredFile -Path $PSCommandPath -Label 'PowerShell wrapper'
$createTcl = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'create_bringup_platform.tcl'
) -Label 'platform create Tcl'
$assertTcl = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'assert_bringup_platform.tcl'
) -Label 'platform assertion Tcl'
$buildTcl = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'build_bringup_platform.tcl'
) -Label 'platform build Tcl'
$clockRtl = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'rtl\zybo_pl_clock.v'
) -Label 'clock RTL'
$clockStubs = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'tb\zybo_clock_primitive_stubs.v'
) -Label 'clock primitive stubs'
$clockTestbench = Resolve-RequiredFile -Path (
    Join-Path $PSScriptRoot 'tb\tb_zybo_pl_clock.v'
) -Label 'clock testbench'
$vivadoPath = Resolve-RequiredFile -Path $VivadoExecutable -Label 'Vivado launcher'
if ([IO.Path]::GetFileName($vivadoPath) -ne 'vivado.bat' -or
    $vivadoPath -notmatch '(?i)[\\/]2025\.1[\\/]') {
    throw "Vivado launcher must be the 2025.1 vivado.bat: $vivadoPath"
}

$outputPath = Resolve-NewDirectoryPath -Path $OutputDirectory `
    -Label 'platform output' -MaximumLength 100
$evidencePath = Resolve-NewDirectoryPath -Path $EvidenceDirectory `
    -Label 'evidence directory' -MaximumLength 140
if (Test-PathsOverlap -Left $outputPath -Right $evidencePath) {
    throw 'platform output and evidence directory must be disjoint'
}

foreach ($pair in @(
    @($scriptPath, 'PowerShell wrapper'),
    @($createTcl, 'platform create Tcl'),
    @($assertTcl, 'platform assertion Tcl'),
    @($buildTcl, 'platform build Tcl'),
    @($clockRtl, 'clock RTL'),
    @($clockStubs, 'clock primitive stubs'),
    @($clockTestbench, 'clock testbench'),
    @($vivadoPath, 'Vivado launcher'),
    @($outputPath, 'platform output'),
    @($evidencePath, 'evidence directory')
)) {
    Assert-CmdSafePath -Path $pair[0] -Label $pair[1]
}

$avDiagRepositoryPath = $null
$avDiagComponentIdentity = $null
if (-not [string]::IsNullOrWhiteSpace($env:TERNARYCORE_AV_DIAG_IP_REPO)) {
    $avDiagRepositoryPath = Resolve-RequiredDirectory `
        -Path $env:TERNARYCORE_AV_DIAG_IP_REPO `
        -Label 'AV diagnostic IP repository'
    $avDiagComponentPath = Resolve-RequiredFile -Path (
        Join-Path $avDiagRepositoryPath 'axi_v5_av_diag\component.xml'
    ) -Label 'AV diagnostic IP component'
    Assert-CmdSafePath -Path $avDiagRepositoryPath `
        -Label 'AV diagnostic IP repository'
    Assert-CmdSafePath -Path $avDiagComponentPath `
        -Label 'AV diagnostic IP component'
    $env:TERNARYCORE_AV_DIAG_IP_REPO = $avDiagRepositoryPath
    $avDiagComponentIdentity = [pscustomobject](
        Get-FileIdentity -Path $avDiagComponentPath
    )
}

$rawFullRepositoryPath = $null
$rawFullComponentIdentity = $null
$rawFullQkMultStyle = 0
$rawFullAvMultStyle = 0
$rawFullProfileName = 'NONE'
if (-not [string]::IsNullOrWhiteSpace($env:TERNARYCORE_RAW_FULL_IP_REPO)) {
    foreach ($exclusiveName in @(
        'TERNARYCORE_KV_IP_REPO',
        'TERNARYCORE_KV_TRANSPORT',
        'TERNARYCORE_AV_DIAG_IP_REPO',
        'TERNARYCORE_CANNED_PAGE_IP_REPO'
    )) {
        if (-not [string]::IsNullOrWhiteSpace(
                [Environment]::GetEnvironmentVariable($exclusiveName, 'Process'))) {
            throw "TERNARYCORE_RAW_FULL_IP_REPO replaces and cannot coexist with $exclusiveName"
        }
    }
    $rawFullRepositoryPath = Resolve-RequiredDirectory `
        -Path $env:TERNARYCORE_RAW_FULL_IP_REPO `
        -Label 'raw-full diagnostic IP repository'
    $rawFullComponentPath = Resolve-RequiredFile -Path (
        Join-Path $rawFullRepositoryPath 'axi_kvq_raw_full_diag\component.xml'
    ) -Label 'raw-full diagnostic IP component'
    Assert-CmdSafePath -Path $rawFullRepositoryPath `
        -Label 'raw-full diagnostic IP repository'
    Assert-CmdSafePath -Path $rawFullComponentPath `
        -Label 'raw-full diagnostic IP component'
    $rawFullProfileName = $RawFullProfile.ToUpperInvariant()
    switch ($rawFullProfileName) {
        'BALANCED' {
            $rawFullQkMultStyle = 2
            $rawFullAvMultStyle = 2
        }
        'LUT_RELIEF' {
            $rawFullQkMultStyle = 2
            $rawFullAvMultStyle = 1
        }
        default { throw "unsupported raw-full profile: $rawFullProfileName" }
    }
    $env:TERNARYCORE_RAW_FULL_IP_REPO = $rawFullRepositoryPath
    $env:TERNARYCORE_RAW_FULL_AXI_WIDTH = [string]$RawFullAxiWidth
    $env:TERNARYCORE_RAW_FULL_SCALE_WIDTH = [string]$RawFullScaleWidth
    $env:TERNARYCORE_RAW_FULL_PROFILE = $rawFullProfileName
    $rawFullComponentIdentity = [pscustomobject](
        Get-FileIdentity -Path $rawFullComponentPath
    )
} elseif ($PSBoundParameters.ContainsKey('RawFullAxiWidth') -or
          $PSBoundParameters.ContainsKey('RawFullScaleWidth') -or
          $PSBoundParameters.ContainsKey('RawFullProfile')) {
    throw '-RawFullAxiWidth, -RawFullScaleWidth, and -RawFullProfile require TERNARYCORE_RAW_FULL_IP_REPO'
}

$rawE2eRepositoryPath = $null
$rawE2eProjectionIdentity = $null
$rawE2eWeightIdentity = $null
if (-not [string]::IsNullOrWhiteSpace($env:TERNARYCORE_RAW_E2E_IP_REPO)) {
    $rawE2eRepositoryPath = Resolve-RequiredDirectory `
        -Path $env:TERNARYCORE_RAW_E2E_IP_REPO -Label 'RAW-E2E IP repository'
    $rawE2eProjectionPath = Resolve-RequiredFile -Path (
        Join-Path $rawE2eRepositoryPath 'axi_gemm_stream\component.xml'
    ) -Label 'RAW-E2E projection component'
    $rawE2eWeightPath = Resolve-RequiredFile -Path (
        Join-Path $rawE2eRepositoryPath 'weight_bram128\component.xml'
    ) -Label 'RAW-E2E weight component'
    foreach ($pair in @(
        @($rawE2eRepositoryPath, 'RAW-E2E IP repository'),
        @($rawE2eProjectionPath, 'RAW-E2E projection component'),
        @($rawE2eWeightPath, 'RAW-E2E weight component')
    )) { Assert-CmdSafePath -Path $pair[0] -Label $pair[1] }
    $env:TERNARYCORE_RAW_E2E_IP_REPO = $rawE2eRepositoryPath
    $rawE2eProjectionIdentity = [pscustomobject](Get-FileIdentity -Path $rawE2eProjectionPath)
    $rawE2eWeightIdentity = [pscustomobject](Get-FileIdentity -Path $rawE2eWeightPath)
}

$cannedPageRepositoryPath = $null
$cannedPageComponentIdentity = $null
$cannedPageQkMultStyle = 0
$cannedPageAvMultStyle = 0
$cannedPageProfileName = 'NONE'
if (-not [string]::IsNullOrWhiteSpace(
        $env:TERNARYCORE_CANNED_PAGE_IP_REPO)) {
    foreach ($exclusiveName in @(
        'TERNARYCORE_KV_IP_REPO',
        'TERNARYCORE_KV_TRANSPORT',
        'TERNARYCORE_AV_DIAG_IP_REPO',
        'TERNARYCORE_RAW_FULL_IP_REPO'
    )) {
        if (-not [string]::IsNullOrWhiteSpace(
                [Environment]::GetEnvironmentVariable(
                    $exclusiveName, 'Process'))) {
            throw "TERNARYCORE_CANNED_PAGE_IP_REPO replaces and cannot coexist with $exclusiveName"
        }
    }
    $cannedPageRepositoryPath = Resolve-RequiredDirectory `
        -Path $env:TERNARYCORE_CANNED_PAGE_IP_REPO `
        -Label 'canned-page diagnostic IP repository'
    $cannedPageComponentPath = Resolve-RequiredFile -Path (
        Join-Path $cannedPageRepositoryPath `
            'axi_kvq_canned_page_diag\component.xml'
    ) -Label 'canned-page diagnostic IP component'
    Assert-CmdSafePath -Path $cannedPageRepositoryPath `
        -Label 'canned-page diagnostic IP repository'
    Assert-CmdSafePath -Path $cannedPageComponentPath `
        -Label 'canned-page diagnostic IP component'
    $cannedPageProfileName = $CannedPageProfile.ToUpperInvariant()
    switch ($cannedPageProfileName) {
        'BALANCED' {
            $cannedPageQkMultStyle = 2
            $cannedPageAvMultStyle = 2
        }
        'LUT_RELIEF' {
            $cannedPageQkMultStyle = 2
            $cannedPageAvMultStyle = 1
        }
        default {
            throw "unsupported canned-page profile: $cannedPageProfileName"
        }
    }
    $env:TERNARYCORE_CANNED_PAGE_IP_REPO = $cannedPageRepositoryPath
    $env:TERNARYCORE_CANNED_PAGE_SCALE_BITS = [string]$CannedPageScaleBits
    $env:TERNARYCORE_CANNED_PAGE_DECODE_LANES =
        [string]$CannedPageDecodeLanes
    $env:TERNARYCORE_CANNED_PAGE_PROFILE = $cannedPageProfileName
    $cannedPageComponentIdentity = [pscustomobject](
        Get-FileIdentity -Path $cannedPageComponentPath
    )
} elseif ($PSBoundParameters.ContainsKey('CannedPageScaleBits') -or
          $PSBoundParameters.ContainsKey('CannedPageDecodeLanes') -or
          $PSBoundParameters.ContainsKey('CannedPageProfile')) {
    throw '-CannedPageScaleBits, -CannedPageDecodeLanes, and -CannedPageProfile require TERNARYCORE_CANNED_PAGE_IP_REPO'
} elseif (-not [string]::IsNullOrWhiteSpace(
             $env:TERNARYCORE_CANNED_PAGE_SCALE_BITS) -or
          -not [string]::IsNullOrWhiteSpace(
             $env:TERNARYCORE_CANNED_PAGE_PROFILE) -or
          -not [string]::IsNullOrWhiteSpace(
             $env:TERNARYCORE_CANNED_PAGE_DECODE_LANES)) {
    throw 'TERNARYCORE_CANNED_PAGE_SCALE_BITS, TERNARYCORE_CANNED_PAGE_DECODE_LANES, and TERNARYCORE_CANNED_PAGE_PROFILE require TERNARYCORE_CANNED_PAGE_IP_REPO'
}

if ($null -ne $rawE2eRepositoryPath) {
    $rawCombinedProfile =
        $null -ne $rawFullRepositoryPath -and
        $null -eq $cannedPageRepositoryPath -and
        $RawFullAxiWidth -eq 64 -and
        $RawFullScaleWidth -eq 12 -and
        $rawFullProfileName -ceq 'LUT_RELIEF'
    $compressedCombinedProfile =
        $null -eq $rawFullRepositoryPath -and
        $null -ne $cannedPageRepositoryPath -and
        $CannedPageScaleBits -eq 12 -and
        $CannedPageDecodeLanes -eq 2 -and
        $cannedPageProfileName -ceq 'LUT_RELIEF'
    if (-not ($rawCombinedProfile -xor $compressedCombinedProfile)) {
        throw 'Tier2 projection requires exactly one accepted KVQ profile: RAW_FULL HP64/SCALE12/LUT_RELIEF or CANNED_PAGE 2x1/SCALE12/LUT_RELIEF'
    }
}

$gitPath = Find-GitExecutable
$gitDirectory = Resolve-RequiredDirectory -Path (Split-Path -Parent $gitPath) `
    -Label 'Git executable directory'
if ($gitDirectory.Contains([IO.Path]::PathSeparator)) {
    throw "Git executable directory contains the PATH separator and cannot be safely prepended: $gitDirectory"
}
$repositoryRootOutput = @(& $gitPath -C $PSScriptRoot rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or $repositoryRootOutput.Count -ne 1) {
    throw 'Git could not resolve the repository containing the platform wrapper'
}
$repositoryRoot = [IO.Path]::GetFullPath([string]$repositoryRootOutput[0])
$repositoryCommitOutput = @(& $gitPath -C $repositoryRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $repositoryCommitOutput.Count -ne 1) {
    throw 'Git could not resolve repository HEAD'
}
$repositoryCommit = [string]$repositoryCommitOutput[0]
$repositoryDirty = (@(& $gitPath -C $repositoryRoot status --porcelain=v1 `
    --untracked-files=all)).Count -gt 0
if ($LASTEXITCODE -ne 0) {
    throw 'Git could not inspect repository status'
}
$worktreeOutput = @(& $gitPath -C $repositoryRoot worktree list --porcelain)
if ($LASTEXITCODE -ne 0) {
    throw 'Git worktree discovery failed'
}
$protectedWorktrees = @(
    $worktreeOutput |
        Where-Object { $_ -like 'worktree *' } |
        ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) }
    $repositoryRoot
) | Sort-Object -Unique
foreach ($root in $protectedWorktrees) {
    if (Test-PathsOverlap -Left $outputPath -Right $root) {
        throw "platform output overlaps protected Git worktree $root`: $outputPath"
    }
    if (Test-PathsOverlap -Left $evidencePath -Right $root) {
        throw "evidence directory overlaps protected Git worktree $root`: $evidencePath"
    }
}

if ([string]::IsNullOrWhiteSpace($env:TERNARYCORE_BOARD_FILES)) {
    throw 'TERNARYCORE_BOARD_FILES must identify the pinned Digilent board-files directory'
}
$boardFilesPath = Resolve-RequiredDirectory -Path $env:TERNARYCORE_BOARD_FILES `
    -Label 'Digilent board-files directory'
$boardRepositoryOutput = @(& $gitPath -C $boardFilesPath rev-parse --show-toplevel)
if ($LASTEXITCODE -ne 0 -or $boardRepositoryOutput.Count -ne 1) {
    throw 'Git could not resolve the Digilent board repository'
}
$boardRepositoryRoot = [IO.Path]::GetFullPath([string]$boardRepositoryOutput[0])
if (Test-PathsOverlap -Left $outputPath -Right $boardRepositoryRoot) {
    throw "platform output overlaps the pinned Digilent board repository $boardRepositoryRoot`: $outputPath"
}
if (Test-PathsOverlap -Left $evidencePath -Right $boardRepositoryRoot) {
    throw "evidence directory overlaps the pinned Digilent board repository $boardRepositoryRoot`: $evidencePath"
}
$boardCommitOutput = @(& $gitPath -C $boardRepositoryRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $boardCommitOutput.Count -ne 1) {
    throw 'Git could not resolve the Digilent board repository commit'
}
$boardCommit = [string]$boardCommitOutput[0]
$pinnedBoardCommit = '36f34ab687b7fa9c778b779d027f3bce63b3ace9'
if ($boardCommit -cne $pinnedBoardCommit) {
    throw "Digilent board repository must be pinned at $pinnedBoardCommit; got $boardCommit"
}
$boardDirtyLines = @(& $gitPath -C $boardRepositoryRoot status --porcelain=v1 `
    --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $boardDirtyLines.Count -ne 0) {
    throw 'Digilent board repository must be clean'
}

$sourcePaths = @(
    $scriptPath, $createTcl, $assertTcl, $buildTcl,
    $clockRtl, $clockStubs, $clockTestbench
)
$sourceIdentities = @($sourcePaths | ForEach-Object {
    [pscustomobject](Get-FileIdentity -Path $_)
})
$vivadoIdentity = Get-FileIdentity -Path $vivadoPath
$gitIdentity = Get-FileIdentity -Path $gitPath
$psuMessage = 'PS DDR interfaces might fail when entering negative DQS skew values.'
$allowedCriticalWarnings = [ordered]@{
    'PSU-1' = [pscustomobject][ordered]@{
        id = 'PSU-1'; parameter = 'PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0'
        parameter_index = 0; value = '-0.050'; message = $psuMessage
    }
    'PSU-2' = [pscustomobject][ordered]@{
        id = 'PSU-2'; parameter = 'PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1'
        parameter_index = 1; value = '-0.044'; message = $psuMessage
    }
    'PSU-3' = [pscustomobject][ordered]@{
        id = 'PSU-3'; parameter = 'PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2'
        parameter_index = 2; value = '-0.035'; message = $psuMessage
    }
    'PSU-4' = [pscustomobject][ordered]@{
        id = 'PSU-4'; parameter = 'PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3'
        parameter_index = 3; value = '-0.100'; message = $psuMessage
    }
}
$allowedCriticalWarningContract = @($allowedCriticalWarnings.Values)

$null = New-Item -ItemType Directory -Path $evidencePath
$temporaryPath = Join-Path $evidencePath 'launcher-tmp'
$null = New-Item -ItemType Directory -Path $temporaryPath
$runInputsPath = Join-Path $evidencePath 'RUN_INPUTS.json'
$runIdentityPath = Join-Path $evidencePath 'RUN_IDENTITY.json'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$runStartedUtc = [DateTime]::UtcNow
$runInputs = [ordered]@{
    schema = 'zybo-vivado-launch-inputs-v3'
    started_utc = $runStartedUtc.ToString('o')
    clock_mhz = $ClockMHz
    jobs = $Jobs
    timeout_seconds_per_stage = $TimeoutSeconds
    output_directory = $outputPath
    evidence_directory = $evidencePath
    working_directory = $evidencePath
    temporary_directory = $temporaryPath
    build_configuration = [ordered]@{
        native_fclk = [Environment]::GetEnvironmentVariable(
            'TERNARYCORE_NATIVE_FCLK', 'Process')
        kv_ip_repository = [Environment]::GetEnvironmentVariable(
            'TERNARYCORE_KV_IP_REPO', 'Process')
        kv_transport = [Environment]::GetEnvironmentVariable(
            'TERNARYCORE_KV_TRANSPORT', 'Process')
        av_diag_ip_repository = $avDiagRepositoryPath
        av_diag_component = $avDiagComponentIdentity
        raw_full_ip_repository = $rawFullRepositoryPath
        raw_full_component = $rawFullComponentIdentity
        raw_full_m_axi_data_width = if ($null -eq $rawFullRepositoryPath) { 0 } else { $RawFullAxiWidth }
        raw_full_scale_width = if ($null -eq $rawFullRepositoryPath) { 0 } else { $RawFullScaleWidth }
        raw_full_qk_mult_style = $rawFullQkMultStyle
        raw_full_av_mult_style = $rawFullAvMultStyle
        raw_full_profile = if ($null -eq $rawFullRepositoryPath) { 'NONE' } else { $rawFullProfileName }
        raw_e2e_ip_repository = $rawE2eRepositoryPath
        raw_e2e_projection_component = $rawE2eProjectionIdentity
        raw_e2e_weight_component = $rawE2eWeightIdentity
        canned_page_ip_repository = $cannedPageRepositoryPath
        canned_page_component = $cannedPageComponentIdentity
        canned_page_scale_bits = if ($null -eq $cannedPageRepositoryPath) { 0 } else { $CannedPageScaleBits }
        canned_page_decode_lanes = if ($null -eq $cannedPageRepositoryPath) { 0 } else { $CannedPageDecodeLanes }
        canned_page_qk_mult_style = $cannedPageQkMultStyle
        canned_page_av_mult_style = $cannedPageAvMultStyle
        canned_page_profile = if ($null -eq $cannedPageRepositoryPath) { 'NONE' } else { $cannedPageProfileName }
        canned_page_compiled_profile_id = if ($null -eq $cannedPageRepositoryPath) { 0 } else { 51 }
        canned_page_compiled_k_codebook_id = if ($null -eq $cannedPageRepositoryPath) { 0 } else { 1 }
        canned_page_compiled_v_codebook_id = if ($null -eq $cannedPageRepositoryPath) { 0 } else { 2 }
    }
    repository = [ordered]@{
        root = $repositoryRoot
        commit = $repositoryCommit
        dirty = $repositoryDirty
        protected_worktrees = $protectedWorktrees
    }
    board_repository = [ordered]@{
        board_files_directory = $boardFilesPath
        root = $boardRepositoryRoot
        commit = $boardCommit
        clean = $true
    }
    allowed_critical_warning_contract = $allowedCriticalWarningContract
    git = [ordered]@{
        executable = $gitIdentity
        directory_prepended_to_child_path = $gitDirectory
    }
    vivado = $vivadoIdentity
    sources = $sourceIdentities
}
[IO.File]::WriteAllText(
    $runInputsPath,
    ($runInputs | ConvertTo-Json -Depth 12) + "`n",
    $utf8NoBom
)

$createResult = $null
$buildResult = $null
$createArtifacts = @()
$buildArtifacts = @()
$overallError = $null
$success = $false

try {
    $createResult = Invoke-VivadoStage `
        -StageName 'create' `
        -VivadoPath $vivadoPath `
        -TclSource $createTcl `
        -TclArguments @($outputPath, $ClockMHz) `
        -ExpectedPassToken 'ZYBO_PLATFORM_CREATE_PASS' `
        -EvidencePath $evidencePath `
        -TemporaryPath $temporaryPath `
        -GeneratedOutputPath $outputPath `
        -GitDirectory $gitDirectory `
        -AllowedCriticalWarnings $allowedCriticalWarnings `
        -StageTimeoutSeconds $TimeoutSeconds
    if ($createResult.result -ne 'PASS') {
        throw 'Vivado create stage failed its exit, token, log, or message gate'
    }

    $createArtifacts = Get-RequiredArtifactIdentities -Label 'create artifact' -Paths @(
        (Join-Path $outputPath '.create_complete'),
        (Join-Path $outputPath 'identity\manifest.tcl'),
        (Join-Path $outputPath 'identity\identity.txt'),
        (Join-Path $outputPath 'project\zybo_bringup.xpr')
    )

    $buildResult = Invoke-VivadoStage `
        -StageName 'build' `
        -VivadoPath $vivadoPath `
        -TclSource $buildTcl `
        -TclArguments @($outputPath, [string]$Jobs) `
        -ExpectedPassToken 'ZYBO_PLATFORM_BUILD_PASS' `
        -EvidencePath $evidencePath `
        -TemporaryPath $temporaryPath `
        -GeneratedOutputPath $outputPath `
        -GitDirectory $gitDirectory `
        -AllowedCriticalWarnings $allowedCriticalWarnings `
        -StageTimeoutSeconds $TimeoutSeconds
    if ($buildResult.result -ne 'PASS') {
        throw 'Vivado build stage failed its exit, token, log, or message gate'
    }

    $bitstreams = @(Get-ChildItem -LiteralPath (Join-Path $outputPath 'artifacts') `
        -Filter '*.bit' -File -ErrorAction Stop)
    $xsas = @(Get-ChildItem -LiteralPath (Join-Path $outputPath 'artifacts') `
        -Filter '*.xsa' -File -ErrorAction Stop)
    if ($bitstreams.Count -ne 1 -or $xsas.Count -ne 1) {
        throw "expected exactly one bitstream and one XSA; got bit=$($bitstreams.Count), xsa=$($xsas.Count)"
    }
    $buildArtifacts = Get-RequiredArtifactIdentities -Label 'build artifact' -Paths @(
        (Join-Path $outputPath '.build_complete'),
        $bitstreams[0].FullName,
        $xsas[0].FullName,
        (Join-Path $outputPath 'artifacts\ps7_init.tcl'),
        (Join-Path $outputPath 'artifacts\SHA256SUMS.txt'),
        (Join-Path $outputPath 'artifacts\build_result.tcl'),
        (Join-Path $outputPath 'reports\timing_summary.rpt'),
        (Join-Path $outputPath 'reports\utilization.rpt'),
        (Join-Path $outputPath 'reports\hierarchical_utilization.rpt'),
        (Join-Path $outputPath 'reports\critical_paths.rpt'),
        (Join-Path $outputPath 'reports\hold_critical_paths.rpt'),
        (Join-Path $outputPath 'reports\control_sets.rpt'),
        (Join-Path $outputPath 'reports\high_fanout_nets.rpt'),
        (Join-Path $outputPath 'reports\clock_utilization.rpt'),
        (Join-Path $outputPath 'reports\drc.rpt'),
        (Join-Path $outputPath 'reports\methodology.rpt'),
        (Join-Path $outputPath 'reports\cdc.rpt')
    )

    foreach ($initialSource in $sourceIdentities) {
        $currentHash = (Get-FileHash -LiteralPath $initialSource.path `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -cne $initialSource.sha256) {
            throw "platform source changed during run: $($initialSource.path)"
        }
    }
    if ($null -ne $avDiagComponentIdentity) {
        $currentAvDiagComponentHash = (
            Get-FileHash -LiteralPath $avDiagComponentIdentity.path -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($currentAvDiagComponentHash -cne $avDiagComponentIdentity.sha256) {
            throw 'AV diagnostic IP component changed during platform run'
        }
    }
    if ($null -ne $rawFullComponentIdentity) {
        $currentRawFullComponentHash = (
            Get-FileHash -LiteralPath $rawFullComponentIdentity.path -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($currentRawFullComponentHash -cne $rawFullComponentIdentity.sha256) {
            throw 'raw-full diagnostic IP component changed during platform run'
        }
    }
    foreach ($component in @($rawE2eProjectionIdentity, $rawE2eWeightIdentity)) {
        if ($null -ne $component) {
            $currentHash = (Get-FileHash -LiteralPath $component.path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -cne $component.sha256) {
                throw "RAW-E2E component changed during platform run: $($component.path)"
            }
        }
    }
    if ($null -ne $cannedPageComponentIdentity) {
        $currentCannedPageComponentHash = (
            Get-FileHash -LiteralPath $cannedPageComponentIdentity.path `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($currentCannedPageComponentHash -cne
            $cannedPageComponentIdentity.sha256) {
            throw 'canned-page diagnostic IP component changed during platform run'
        }
    }
    $currentRepositoryCommit = @(& $gitPath -C $repositoryRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $currentRepositoryCommit.Count -ne 1 -or
        [string]$currentRepositoryCommit[0] -cne $repositoryCommit) {
        throw 'repository HEAD changed during platform run'
    }
    $currentBoardCommit = @(& $gitPath -C $boardRepositoryRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $currentBoardCommit.Count -ne 1 -or
        [string]$currentBoardCommit[0] -cne $pinnedBoardCommit) {
        throw 'Digilent board repository commit changed during platform run'
    }
    $success = $true
} catch {
    $overallError = $_.Exception.Message
}

$allowlistedOccurrences = @()
$unexpectedOccurrences = @()
foreach ($stageResult in @($createResult, $buildResult)) {
    if ($null -ne $stageResult) {
        $allowlistedOccurrences += @(
            $stageResult.message_scan.allowlisted_critical_warning_occurrences
        )
        $unexpectedOccurrences += @(
            $stageResult.message_scan.unexpected_critical_warning_occurrences
        )
    }
}
$runIdentity = [ordered]@{
    schema = 'zybo-vivado-launch-result-v3'
    result = if ($success) { 'PASS' } else { 'FAIL' }
    started_utc = $runStartedUtc.ToString('o')
    ended_utc = [DateTime]::UtcNow.ToString('o')
    error = $overallError
    input_identity = Get-FileIdentity -Path $runInputsPath
    clock_mhz = $ClockMHz
    jobs = $Jobs
    output_directory = $outputPath
    evidence_directory = $evidencePath
    allowed_critical_warning_contract = $allowedCriticalWarningContract
    allowlisted_critical_warning_occurrences = $allowlistedOccurrences
    unexpected_critical_warning_occurrences = $unexpectedOccurrences
    create = $createResult
    build = $buildResult
    create_artifacts = $createArtifacts
    build_artifacts = $buildArtifacts
}
[IO.File]::WriteAllText(
    $runIdentityPath,
    ($runIdentity | ConvertTo-Json -Depth 16) + "`n",
    $utf8NoBom
)

if (-not $success) {
    throw "ZYBO_PLATFORM_LAUNCH_FAIL; retained evidence: $evidencePath; reason: $overallError"
}

Write-Output 'ZYBO_PLATFORM_LAUNCH_PASS'
Write-Output "Platform output: $outputPath"
Write-Output "Run identity: $runIdentityPath"
