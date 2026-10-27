[CmdletBinding()]
param(
    [string]$Region = 'cn-hongkong',
    [string]$InstanceId = 'i-j6cdji1nji415swaliji',
    [string]$Profile = 'xiaoqi-remote-deploy',
    [string]$Endpoint = 'ecs.aliyuncs.com',
    [string]$PublicHealthUrl = 'https://47-76-60-77.sslip.io/health',
    [ValidateSet('full', 'non-image')][string]$VerificationProfile = 'full'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RemoteRoot = '/opt/xiaoqi-single-server'
$DeployDir = $PSScriptRoot
$HarnessDir = Split-Path -Parent $DeployDir
$ManagerPath = Join-Path $DeployDir 'release_manager.sh'
. (Join-Path $DeployDir 'github_build.ps1')
$serverReleaseSource = Get-Content -Raw -LiteralPath (Join-Path $HarnessDir 'genkit_server/lib/src/release.dart')
$clientReleaseSource = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $HarnessDir) 'lib/config/release.dart')
$productRelease = [regex]::Match($serverReleaseSource, "const releaseId = '([^']+)'").Groups[1].Value
$contractVersion = [regex]::Match($serverReleaseSource, "const apiContractVersion = '([^']+)'").Groups[1].Value
if (-not $productRelease -or -not $contractVersion -or
    $clientReleaseSource -notmatch [regex]::Escape("const releaseId = '$productRelease'") -or
    $clientReleaseSource -notmatch [regex]::Escape("const apiContractVersion = '$contractVersion'")) {
    throw 'Client and server release/contract identifiers must match before deployment.'
}

function Invoke-AliyunJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $cliArguments = @($Arguments + @('--endpoint', $Endpoint))
    $maxAttempts = if ($Arguments[1] -like 'Describe*') { 4 } else { 1 }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $output = & aliyun @cliArguments 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $parsed = $output | ConvertFrom-Json
            if (-not ($parsed.PSObject.Properties.Name -contains 'message' -and $parsed.PSObject.Properties.Name -contains 'schemaVersion')) {
                return $parsed
            }
        }
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw "Alibaba Cloud command $($Arguments[1]) failed after $maxAttempts attempt(s). A write is never blindly retried.`n$output"
}

function Get-OptionalField {
    param($Value, [string]$Name, $Default = $null)
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Wait-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$InvokeId,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-AliyunJson -Arguments @(
                'ecs', 'DescribeInvocationResults',
                '--profile', $Profile,
                '--region', $Region,
                '--RegionId', $Region,
                '--InvokeId', $InvokeId,
                '--InstanceId', $InstanceId
            )
        } catch {
            if ((Get-Date) -ge $deadline) { throw }
            $remainingSeconds = [Math]::Max(1, [int]($deadline - (Get-Date)).TotalSeconds)
            $retryDelay = [Math]::Min(15, [Math]::Min(5, $remainingSeconds))
            Write-Warning "ECS status polling failed temporarily; remote command $InvokeId is still being tracked. Retrying in ${retryDelay}s."
            Start-Sleep -Seconds $retryDelay
            continue
        }
        $invocation = Get-OptionalField $result 'Invocation'
        $results = Get-OptionalField $invocation 'InvocationResults'
        $items = @(Get-OptionalField $results 'InvocationResult')
        $item = if ($items.Count) { $items[0] } else { $null }
        $state = Get-OptionalField $item 'InvocationStatus' 'Pending'
        if ($state -in @('Success', 'Failed', 'Stopped', 'Aborted', 'Timeout')) {
            $output = Get-OptionalField $item 'Output' ''
            $exitCode = Get-OptionalField $item 'ExitCode'
            $errorInfo = Get-OptionalField $item 'ErrorInfo' ''
            $text = if ($output) {
                [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$output))
            } else {
                ''
            }
            if ($state -ne 'Success' -or $null -eq $exitCode -or [int]$exitCode -ne 0) {
                throw "Remote command $state (exit $(if($null -eq $exitCode){'unknown'}else{$exitCode})):`n$text`n$errorInfo"
            }
            return $text.Trim()
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Remote command timed out: $InvokeId"
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$Script,
        [int]$TimeoutSeconds = 1800
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $started = Invoke-AliyunJson -Arguments @(
        'ecs', 'RunCommand',
        '--profile', $Profile,
        '--region', $Region,
        '--RegionId', $Region,
        '--InstanceId.1', $InstanceId,
        '--CommandContent', $encoded,
        '--ContentEncoding', 'Base64',
        '--Type', 'RunShellScript',
        '--Timeout', [string]$TimeoutSeconds,
        '--KeepCommand', 'false'
    )
    return Wait-RemoteCommand -InvokeId ([string]$started.InvokeId) -TimeoutSeconds ($TimeoutSeconds + 30)
}

function Get-VerifiedPublicHealth {
    param([Parameter(Mandatory)][string]$Url)
    $healthUri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$healthUri) -or
        $healthUri.Scheme -ne 'https' -or $healthUri.Port -ne 443 -or
        $healthUri.UserInfo -or $healthUri.Query -or $healthUri.Fragment -or
        $healthUri.AbsolutePath -ne '/health' -or $healthUri.DnsSafeHost -notmatch '^[A-Za-z0-9.-]+$') {
        throw 'Public health must be an HTTPS /health URL without credentials or query parameters.'
    }
    $localCheckSucceeded = $false
    try {
        $healthBody = & curl.exe --fail --silent --show-error --max-time 20 --url $Url 2>&1 | Out-String
        $localCheckSucceeded = $LASTEXITCODE -eq 0
    } catch { $localCheckSucceeded = $false }
    $source = 'local'
    if (-not $localCheckSucceeded) {
        Write-Warning 'Local public TLS check failed; checking the same HTTPS endpoint through Cloud Assistant.'
        $safeUrl = "https://$($healthUri.DnsSafeHost)/health"
        $healthBody = Invoke-RemoteCommand -Script "curl --fail --silent --show-error --max-time 20 --url '$safeUrl'" -TimeoutSeconds 60
        $source = 'cloud_assistant'
    }
    $health = $healthBody | ConvertFrom-Json
    $health | Add-Member -NotePropertyName verification_source -NotePropertyValue $source
    return $health
}

function Send-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$Mode = '0600'
    )

    $started = Invoke-AliyunJson -Arguments @(
        'ecs', 'SendFile',
        '--profile', $Profile,
        '--region', $Region,
        '--RegionId', $Region,
        '--InstanceId.1', $InstanceId,
        '--TargetDir', $TargetDir,
        '--Name', $Name,
        '--ContentType', 'Base64',
        '--Content', [Convert]::ToBase64String($Bytes),
        '--FileMode', $Mode,
        '--Overwrite', 'true'
    )

    $deadline = (Get-Date).AddMinutes(3)
    do {
        $result = Invoke-AliyunJson -Arguments @(
            'ecs', 'DescribeSendFileResults',
            '--profile', $Profile,
            '--region', $Region,
            '--RegionId', $Region,
            '--InvokeId', [string]$started.InvokeId,
            '--InstanceId', $InstanceId
        )
        $invocation = @($result.Invocations.Invocation)[0]
        $instance = if ($null -ne $invocation) { @($invocation.InvokeInstances.InvokeInstance)[0] } else { $null }
        if ($null -ne $instance -and $instance.InvocationStatus -in @('Success', 'Failed')) {
            if ($instance.InvocationStatus -ne 'Success') {
                throw "File upload failed: $Name - $($instance.ErrorInfo)"
            }
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "File upload timed out: $Name"
}

function Save-RemoteDeploymentLog {
    param([string]$ReleaseId, [string]$LocalPath)
    $offset = 0
    $stream = [IO.File]::Open($LocalPath, [IO.FileMode]::Create)
    try {
        do {
            $chunk = Invoke-RemoteCommand -Script "dd if='$RemoteRoot/logs/$ReleaseId.log' bs=3900 skip=$offset count=1 status=none | base64 -w0" -TimeoutSeconds 60
            $bytes = [byte[]]@()
            if ($chunk) { $bytes = [Convert]::FromBase64String($chunk) }
            $stream.Write($bytes, 0, $bytes.Length)
            $offset++
        } while ($bytes.Length -eq 3900)
    } finally { $stream.Dispose() }
    Write-Host "DEPLOY_LOG $LocalPath"
}

function Wait-DeploymentJob {
    param([string]$ReleaseId, [string]$LocalLog)
    $deadline = (Get-Date).AddMinutes(50)
    $lastPhase = ''
    do {
        try {
            $snapshot = Invoke-RemoteCommand -Script "if test -f '$RemoteRoot/incoming/$ReleaseId/result'; then printf 'RESULT='; cat '$RemoteRoot/incoming/$ReleaseId/result'; else printf 'RESULT=running\n'; fi; grep 'PHASE=' '$RemoteRoot/logs/$ReleaseId.log' 2>/dev/null | tail -1 || true" -TimeoutSeconds 60
        } catch {
            Write-Warning 'Progress connection interrupted; the independent remote job is still tracked. No redeploy or cleanup was triggered.'
            Start-Sleep -Seconds 15
            continue
        }
        $phase = [regex]::Match($snapshot, 'PHASE=([^\r\n]+)').Groups[1].Value
        if ($phase -and $phase -ne $lastPhase) { Write-Host "DEPLOY_PHASE $phase"; $lastPhase = $phase }
        $result = [regex]::Match($snapshot, '(?m)^RESULT=([^\r\n]+)').Groups[1].Value
        if ($result -match '^\d+$') {
            Save-RemoteDeploymentLog -ReleaseId $ReleaseId -LocalPath $LocalLog
            if ($result -ne '0') {
                $tail = Get-Content -LiteralPath $LocalLog -Tail 16 | Out-String
                throw "Remote deployment failed (exit $result). Full log: $LocalLog`n$tail"
            }
            return
        }
        Write-Host "DEPLOY_WAIT phase=$phase"
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    throw "Progress wait timed out. The remote job and log remain at $RemoteRoot/logs/$ReleaseId.log; do not start another deployment until its result is checked."
}

if (-not (Get-Command aliyun -ErrorAction SilentlyContinue)) {
    throw 'aliyun CLI is not installed.'
}
if (-not (Test-Path -LiteralPath $ManagerPath -PathType Leaf)) {
    throw "Missing release manager: $ManagerPath"
}

$mainCommit = Get-MainReleaseCommit -RepositoryRoot (Split-Path -Parent $HarnessDir)
$gitRevision = $mainCommit.Substring(0, 7)
$releaseId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$gitRevision"
$incomingDir = "$RemoteRoot/incoming/$releaseId"
$localLockPath = Join-Path ([IO.Path]::GetTempPath()) 'xiaoqi-deploy-current.lock'
$localLock = $null
$jobStarted = $false
$jobFinished = $false
$logDir = Join-Path (Split-Path -Parent $HarnessDir) '.codex-artifacts/deploy'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$localLog = Join-Path $logDir "$releaseId.log"
try {
    $localLock = [IO.File]::Open($localLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Write-Host '[1/5] Checking the current server before building'
    Invoke-RemoteCommand -Script "set -eu; install -d -m 700 '$RemoteRoot/incoming' '$incomingDir' '$RemoteRoot/logs'" -TimeoutSeconds 60 | Out-Null
    foreach ($name in @('release_manager.sh', 'release_artifact.py', 'run_release_job.sh')) {
        $source = (Get-Content -Raw -LiteralPath (Join-Path $DeployDir $name)) -replace "`r`n", "`n"
        Send-RemoteFile -TargetDir $incomingDir -Name $name -Bytes ([Text.Encoding]::UTF8.GetBytes($source)) -Mode '0700'
    }
    Invoke-RemoteCommand -Script "set -eu; bash -n '$incomingDir/release_manager.sh'; bash -n '$incomingDir/run_release_job.sh'; bash '$incomingDir/release_manager.sh' preflight" -TimeoutSeconds 180 | Write-Host

    Write-Host '[2/5] Building and testing on GitHub Actions (not on production)'
    $build = Get-ServerBuildArtifact -RepositoryRoot (Split-Path -Parent $HarnessDir)
    if ($build.Commit -ne $mainCommit -or (Get-MainReleaseCommit -RepositoryRoot (Split-Path -Parent $HarnessDir)) -ne $mainCommit) {
        throw 'Main changed during the build. The current server was not switched; restart with the current reviewed main.'
    }

    Write-Host '[3/5] Starting the independent remote release job'
    # A single short-lived artifact URL, without a GitHub or cloud credential.
    $downloadConfig = 'url = "' + $build.DownloadUrl + '"' + "`n"
    Send-RemoteFile -TargetDir $incomingDir -Name 'download.conf' -Bytes ([Text.Encoding]::UTF8.GetBytes($downloadConfig))
    Write-Host "Live verification profile: $VerificationProfile. Deferred checks are not marked verified."
    $launch = "set -eu; test ! -e '$incomingDir/started'; touch '$incomingDir/started'; XIAOQI_RELEASE_VERIFICATION_PROFILE='$VerificationProfile' nohup bash '$incomingDir/run_release_job.sh' '$releaseId' '$($build.Commit)' '$productRelease' '$contractVersion' </dev/null >/dev/null 2>&1 & echo JOB_STARTED"
    # Mark ambiguous dispatches as started so finally never removes active inputs.
    $jobStarted = $true
    Invoke-RemoteCommand -Script $launch -TimeoutSeconds 60 | Write-Host

    Write-Host '[4/5] Following download, validation, load, backup and activation'
    Wait-DeploymentJob -ReleaseId $releaseId -LocalLog $localLog
    $jobFinished = $true

    Write-Host '[5/5] Verifying the running service and restore point'
    $status = Invoke-RemoteCommand -Script "set -eu; '$RemoteRoot/release_manager.sh' status" -TimeoutSeconds 180
    Write-Host $status
    $health = Get-VerifiedPublicHealth -Url $PublicHealthUrl
    if ($health.release_id -ne $productRelease -or $health.api_contract_version -ne $contractVersion -or $status -notmatch "current_release=$releaseId" -or $status -notmatch 'current_health=healthy') {
        throw 'Independent release verification failed; inspect the retained remote job log before taking recovery action.'
    }
    try { Remove-OldBuildArtifacts -CurrentRunId $build.RunId } catch { Write-Warning 'Old GitHub artifact cleanup needs a retry; current deployment is healthy.' }
    Write-Host "DEPLOYMENT_VERIFIED public_health=200 via=$($health.verification_source) release=$releaseId product=$productRelease contract=$contractVersion"
}
finally {
    if (-not $jobStarted -or $jobFinished) {
        try {
            Invoke-RemoteCommand -Script "set -eu; test -d '$incomingDir' && find '$incomingDir' -mindepth 1 -maxdepth 1 -type f -delete || true; rmdir '$incomingDir' 2>/dev/null || true" -TimeoutSeconds 60 | Out-Null
        } catch {
            Write-Warning 'Could not clean remote upload files; they remain for diagnosis.'
        }
    }
    if ($null -ne $localLock) { $localLock.Dispose() }
}
