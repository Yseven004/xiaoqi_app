$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'deploy_current.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-OptionalField', 'Wait-RemoteCommand', 'Invoke-AliyunJson')) {
    $definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$script:calls = 0
$script:testState = 'Aborted'
function Invoke-AliyunJson {
    param([string[]]$Arguments)
    $script:calls++
    if ($script:testState -eq 'Aborted') {
        return [pscustomobject]@{Invocation=[pscustomobject]@{InvocationResults=[pscustomobject]@{InvocationResult=@([pscustomobject]@{InvocationStatus='Aborted'; ErrorInfo='agent unavailable'})}}}
    }
    return [pscustomobject]@{Invocation=[pscustomobject]@{InvocationResults=[pscustomobject]@{InvocationResult=@([pscustomobject]@{InvocationStatus='Success'; ExitCode=0; Output=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ok'))})}}}
}
$Profile = 'test'; $Region = 'test'; $InstanceId = 'test'
$rejected = $false
try { Wait-RemoteCommand -InvokeId test -TimeoutSeconds 1 } catch {
    $rejected = $_.Exception.Message -match 'Aborted.*unknown' -and $_.Exception.Message -match 'agent unavailable'
}
if (-not $rejected -or $script:calls -ne 1) { throw 'Missing ExitCode was not handled correctly.' }
$script:testState = 'Success'
if ((Wait-RemoteCommand -InvokeId test -TimeoutSeconds 1) -ne 'ok') { throw 'Successful output decoding failed.' }
if ((Get-OptionalField $null 'Missing' 'fallback') -ne 'fallback') { throw 'Null response fallback failed.' }
# Re-load the real API helper with a fake CLI to verify no write is replayed.
$definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AliyunJson'}, $true)
. ([ScriptBlock]::Create($definition.Extent.Text))
$script:calls = 0
$Endpoint = 'example.com'
function aliyun { $script:calls++; $global:LASTEXITCODE=1; 'ambiguous transport failure' }
try { Invoke-AliyunJson -Arguments @('ecs','RunCommand') | Out-Null } catch { }
if ($script:calls -ne 1) { throw 'Remote write was replayed.' }

$definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-RemoteDeploymentLog'}, $true)
. ([ScriptBlock]::Create($definition.Extent.Text))
$script:logBytes = [Text.Encoding]::UTF8.GetBytes((([string][char]0x65E5 + [char]0x5FD7) * 3000) + 'end')
function Invoke-RemoteCommand {
    param([string]$Script, [int]$TimeoutSeconds)
    $skip = [int][regex]::Match($Script, 'skip=(\d+)').Groups[1].Value
    $offset = $skip * 3900
    $length = [Math]::Max(0, [Math]::Min(3900, $script:logBytes.Length - $offset))
    $chunk = [byte[]]::new($length)
    if ($length) { [Array]::Copy($script:logBytes, $offset, $chunk, 0, $length) }
    [Convert]::ToBase64String($chunk)
}
$RemoteRoot = '/test'
$logFile = [IO.Path]::GetTempFileName()
try {
    $unicodeLog = $script:logBytes
    foreach ($length in @(0, 3900, 7800, $unicodeLog.Length)) {
        $script:logBytes = [byte[]]::new($length)
        if ($length) { [Array]::Copy($unicodeLog, 0, $script:logBytes, 0, $length) }
        Save-RemoteDeploymentLog -ReleaseId test -LocalPath $logFile
        $actual = [Convert]::ToBase64String([IO.File]::ReadAllBytes($logFile))
        if ($actual -ne [Convert]::ToBase64String($script:logBytes)) { throw 'Chunked log retrieval lost bytes.' }
    }
} finally { Remove-Item -LiteralPath $logFile -Force }
Write-Output 'Controller checks passed: missing fields, terminal errors, no mutation retries, and complete multi-chunk UTF-8 logs.'
