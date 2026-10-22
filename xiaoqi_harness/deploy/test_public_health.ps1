$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'deploy_current.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedPublicHealth'}, $true)
. ([ScriptBlock]::Create($definition.Extent.Text))
$script:localFailure = $false
$script:remoteCalls = 0
function curl.exe {
    $global:LASTEXITCODE = if ($script:localFailure) { 35 } else { 0 }
    if ($script:localFailure) { 'TLS handshake failed' }
    else { '{"release_id":"test","api_contract_version":"18"}' }
}
function Invoke-RemoteCommand {
    param([string]$Script, [int]$TimeoutSeconds)
    if ($Script -notmatch "^curl .*'https://example.com/health'$") { throw 'Unexpected remote command' }
    $script:remoteCalls++
    '{"release_id":"test","api_contract_version":"18"}'
}
$local = Get-VerifiedPublicHealth -Url 'https://example.com/health'
if ($local.verification_source -ne 'local' -or $script:remoteCalls -ne 0) { throw 'Local health path failed' }
$script:localFailure = $true
$remote = Get-VerifiedPublicHealth -Url 'https://example.com/health'
if ($remote.verification_source -ne 'cloud_assistant' -or $script:remoteCalls -ne 1 -or $remote.release_id -ne 'test') { throw 'Remote TLS health fallback failed' }
foreach ($url in @('http://example.com/health', 'https://user:secret@example.com/health', 'https://example.com/health?token=secret', "https://example.com/health';touch /tmp/unsafe")) {
    $rejected = $false
    try { Get-VerifiedPublicHealth -Url $url | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe health URL accepted' }
}
Write-Output 'Public health: local, Cloud Assistant fallback and URL safety checks passed.'
