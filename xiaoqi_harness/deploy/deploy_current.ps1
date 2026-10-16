[CmdletBinding()]
param(
    [string]$Region = 'cn-hongkong',
    [string]$InstanceId = 'i-j6cdji1nji415swaliji',
    [string]$Profile = 'xiaoqi-remote-deploy',
    [string]$PublicHealthUrl = 'https://47-76-60-77.sslip.io/health'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RemoteRoot = '/opt/xiaoqi-single-server'
$ChunkSize = 18KB
$DeployDir = $PSScriptRoot
$HarnessDir = Split-Path -Parent $DeployDir
$ManagerPath = Join-Path $DeployDir 'release_manager.sh'
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

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $output = & aliyun @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $parsed = $output | ConvertFrom-Json
            if (-not ($parsed.PSObject.Properties.Name -contains 'message' -and $parsed.PSObject.Properties.Name -contains 'schemaVersion')) {
                return $parsed
            }
        }
        if ($attempt -lt 4) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw "Alibaba Cloud command failed after 4 attempts:`n$output"
}

function Wait-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$InvokeId,
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-AliyunJson -Arguments @(
            'ecs', 'DescribeInvocationResults',
            '--profile', $Profile,
            '--region', $Region,
            '--RegionId', $Region,
            '--InvokeId', $InvokeId,
            '--InstanceId', $InstanceId
        )
        $item = @($result.Invocation.InvocationResults.InvocationResult)[0]
        if ($null -ne $item -and $item.InvocationStatus -in @('Success', 'Failed', 'Stopped')) {
            $text = if ($item.Output) {
                [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$item.Output))
            } else {
                ''
            }
            if ($item.InvocationStatus -ne 'Success' -or [int]$item.ExitCode -ne 0) {
                throw "Remote command failed (exit $($item.ExitCode)):`n$text`n$($item.ErrorInfo)"
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

if (-not (Get-Command aliyun -ErrorAction SilentlyContinue)) {
    throw 'aliyun CLI is not installed.'
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    throw 'tar.exe is not available.'
}
if (-not (Test-Path -LiteralPath $ManagerPath -PathType Leaf)) {
    throw "Missing release manager: $ManagerPath"
}

$gitRevision = (& git -C (Split-Path -Parent $HarnessDir) rev-parse --short HEAD 2>$null | Out-String).Trim()
if (-not $gitRevision) { $gitRevision = 'nogit' }
$releaseId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$gitRevision"
$incomingDir = "$RemoteRoot/incoming/$releaseId"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) "xiaoqi-deploy-$releaseId"
$archivePath = Join-Path $tempDir 'release.tgz'

New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    Write-Host "[1/5] Packaging current source as $releaseId"
    & tar.exe -czf $archivePath `
        '--exclude=genkit_server/.dart_tool' `
        '--exclude=genkit_server/build' `
        '--exclude=genkit_server/coverage' `
        '--exclude=deploy/single-server.env' `
        '--exclude=deploy/backups' `
        '--exclude=deploy/__pycache__' `
        '--exclude=deploy/harness-artifacts' `
        '--exclude=deploy/xiaoqi-agent-worker.zip' `
        -C $HarnessDir genkit_server deploy
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create release archive.' }

    $entries = & tar.exe -tzf $archivePath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect release archive.' }
    if ($entries -match '(^|/)single-server\.env$') { throw 'Refusing to upload server environment secrets.' }
    if ($entries -match '(^|/)\.dart_tool(/|$)') { throw 'Release archive contains .dart_tool.' }

    $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    $archiveBytes = [IO.File]::ReadAllBytes($archivePath)

    Write-Host '[2/5] Preparing the server upload area'
    Invoke-RemoteCommand -Script "set -eu; install -d -m 700 '$RemoteRoot' '$RemoteRoot/incoming' '$incomingDir'; find '$incomingDir' -mindepth 1 -maxdepth 1 -type f -delete" -TimeoutSeconds 60 | Out-Null
    Send-RemoteFile -TargetDir $RemoteRoot -Name 'release_manager.sh' -Bytes ([IO.File]::ReadAllBytes($ManagerPath)) -Mode '0700'

    Write-Host '[3/5] Uploading the release'
    $chunkCount = [Math]::Ceiling($archiveBytes.Length / $ChunkSize)
    for ($index = 0; $index -lt $chunkCount; $index++) {
        $offset = $index * $ChunkSize
        $length = [Math]::Min($ChunkSize, $archiveBytes.Length - $offset)
        $chunk = [byte[]]::new($length)
        [Array]::Copy($archiveBytes, $offset, $chunk, 0, $length)
        Send-RemoteFile -TargetDir $incomingDir -Name ('part-{0:D5}' -f $index) -Bytes $chunk
    }
    Invoke-RemoteCommand -Script "set -eu; cat '$incomingDir'/part-* > '$incomingDir/release.tgz'; printf '%s  %s\n' '$sha256' '$incomingDir/release.tgz' | sha256sum -c -" -TimeoutSeconds 120 | Out-Null

    Write-Host '[4/5] Building, switching, and checking automatic rollback'
    $deployOutput = Invoke-RemoteCommand -Script "set -eu; '$RemoteRoot/release_manager.sh' deploy '$incomingDir/release.tgz' '$releaseId' '$sha256'" -TimeoutSeconds 3600
    Write-Host $deployOutput

    Write-Host '[5/5] Verifying the running service and restore point'
    $status = Invoke-RemoteCommand -Script "set -eu; '$RemoteRoot/release_manager.sh' status" -TimeoutSeconds 180
    Write-Host $status
    $response = Invoke-WebRequest -Uri $PublicHealthUrl -UseBasicParsing -NoProxy -TimeoutSec 20
    if ([int]$response.StatusCode -ne 200) { throw "Public health check returned $($response.StatusCode)." }
    $health = $response.Content | ConvertFrom-Json
    if ($health.release_id -ne $productRelease -or $health.api_contract_version -ne $contractVersion) {
        Invoke-RemoteCommand -Script "set -eu; '$RemoteRoot/release_manager.sh' rollback" -TimeoutSeconds 600 | Write-Host
        throw 'Release/contract verification failed; automatic rollback requested.'
    }
    Write-Host "DEPLOYMENT_VERIFIED public_health=$($response.StatusCode) release=$releaseId product=$productRelease contract=$contractVersion"
}
finally {
    try {
        Invoke-RemoteCommand -Script "set -eu; test -d '$incomingDir' && find '$incomingDir' -mindepth 1 -maxdepth 1 -type f -delete || true; rmdir '$incomingDir' 2>/dev/null || true" -TimeoutSeconds 60 | Out-Null
    } catch {
        Write-Warning "Could not clean remote upload files: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
