[CmdletBinding()]
param([switch]$BuildApk)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $project '.local\capability-chain-verification'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$statusPath = Join-Path $outputDirectory 'status.json'
$phases = [ordered]@{}

function Save-Status {
    $payload = @{ updated_at = (Get-Date).ToString('o'); phases = $phases }
    [IO.File]::WriteAllText($statusPath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Invoke-Check {
    param([string]$Name, [string]$WorkingDirectory, [scriptblock]$Command)
    $phases[$Name] = @{ status = 'running' }
    Save-Status
    Push-Location $WorkingDirectory
    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $Command 2>&1 | Out-String
        $checkExit = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        [IO.File]::WriteAllText((Join-Path $outputDirectory "$Name.log"), $output, [Text.UTF8Encoding]::new($false))
        $phases[$Name] = @{ status = $(if ($checkExit -eq 0) { 'passed' } else { 'failed' }); exit_code = $checkExit }
        Save-Status
        if ($checkExit -ne 0) { throw "$Name failed; see $outputDirectory\$Name.log" }
    } finally { Pop-Location }
}

try {
    $env:XIAOQI_TEST_PYTHON = (& py -3 -c 'import sys; print(sys.executable)').Trim()
    $server = Join-Path $project 'xiaoqi_harness\genkit_server'
    Invoke-Check 'server-analyze' $server { dart analyze }
    Invoke-Check 'server-tests' $server { dart test --reporter json }
    Invoke-Check 'flutter-analyze' $project { .\flutterw.cmd analyze --no-fatal-infos lib/pages/home_page.dart lib/pages/extension_market_page.dart lib/features/ai_study_annotation/data/ai_conversation_history.dart }
    Invoke-Check 'flutter-tests' $project { .\flutterw.cmd test test/capability_scope_history_test.dart test/capability_selection_test.dart --reporter expanded }
    if ($BuildApk) { Invoke-Check 'apk-build' $project { .\flutterw.cmd build apk --release } }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
