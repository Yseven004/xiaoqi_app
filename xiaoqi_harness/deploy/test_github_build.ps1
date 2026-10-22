$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'github_build.ps1')

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern)
    $matched = $false
    try { & $Action | Out-Null } catch { $matched = $_.Exception.Message -match $Pattern }
    if (-not $matched) { throw "Expected rejection: $Pattern" }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$fixture = Join-Path $tempRoot ('xiaoqi-main-guard-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'work'
$remote = Join-Path $fixture 'origin.git'
New-Item -ItemType Directory -Path $repository -Force | Out-Null
try {
    git init --quiet --bare $remote
    git -C $repository init --quiet --initial-branch=main
    git -C $repository config user.email test@example.invalid
    git -C $repository config user.name 'Main guard test'
    Set-Content -LiteralPath (Join-Path $repository 'source.txt') -Value original -Encoding ASCII
    git -C $repository add -- source.txt
    git -C $repository commit --quiet -m initial
    git -C $repository remote add origin $remote
    git -C $repository push --quiet origin main
    if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated Git fixture.' }
    $expected = (& git -C $repository rev-parse HEAD | Out-String).Trim()
    if ((Get-MainReleaseCommit -RepositoryRoot $repository) -ne $expected) { throw 'Clean published main was rejected.' }

    Set-Content -LiteralPath (Join-Path $repository 'source.txt') -Value changed -Encoding ASCII
    Assert-Rejected { Get-MainReleaseCommit -RepositoryRoot $repository } 'working tree must be clean'
    git -C $repository add -- source.txt
    git -C $repository commit --quiet -m reviewed
    Assert-Rejected { Get-MainReleaseCommit -RepositoryRoot $repository } 'local main must match origin/main'
    git -C $repository push --quiet origin main
    git -C $repository switch --quiet -c topic
    Assert-Rejected { Get-MainReleaseCommit -RepositoryRoot $repository } 'requires the main branch'
    git -C $repository switch --quiet main
    $current = Get-MainReleaseCommit -RepositoryRoot $repository
    if ($current -eq $expected) { throw 'Published main did not advance to the reviewed commit.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'xiaoqi-main-guard-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

# Verify run selection and expired-artifact recovery without calling GitHub.
$script:commit = 'a' * 40
$script:queries = 0
$script:dispatches = 0
$script:scenario = 'foreign-runs'
function Get-MainReleaseCommit { param([string]$RepositoryRoot) $script:commit }
function Start-Sleep { param([int]$Seconds) }
function Invoke-GitHubBuildApi {
    param([string]$Path, [string]$Method = 'GET', $Body = $null)
    if ($Method -eq 'POST') {
        if ($Body.ref -ne 'main' -or $Path -notmatch '/server-release.yml/dispatches$') { throw 'Unexpected build dispatch.' }
        $script:dispatches++
        return
    }
    if ($Path -match '/artifacts$') { return [pscustomobject]@{artifacts=@()} }
    $script:queries++
    $branch = 'main'; $sha = $script:commit; $id = [long]$script:queries; $conclusion = 'failure'
    if ($script:scenario -eq 'foreign-runs') {
        if ($script:queries -eq 1) { $branch = 'other'; $conclusion = 'success' }
        if ($script:queries -eq 2) { $sha = 'b' * 40; $conclusion = 'success' }
    } else {
        $id += 10
        if ($script:queries -eq 1) { $conclusion = 'success' }
    }
    $run = [pscustomobject]@{id=$id; path='.github/workflows/server-release.yml'; head_branch=$branch; head_sha=$sha; event='push'; status='completed'; conclusion=$conclusion; html_url='main-run'}
    return [pscustomobject]@{workflow_runs=@($run)}
}
Assert-Rejected { Get-ServerBuildArtifact -RepositoryRoot unused } 'Off-host build failed: main-run'
if ($script:queries -ne 3 -or $script:dispatches -ne 0) { throw 'A foreign branch or commit was accepted.' }
$script:scenario = 'expired'; $script:queries = 0
Assert-Rejected { Get-ServerBuildArtifact -RepositoryRoot unused } 'Off-host build failed: main-run'
if ($script:queries -ne 2 -or $script:dispatches -ne 1) { throw 'Expired artifact did not rebuild exactly once from main.' }
Write-Output 'Main build checks passed: clean/published main, dirty/unpublished/topic rejection, exact run selection, and one expired-artifact rebuild.'
