Set-StrictMode -Version Latest

function Get-GitHubBuildHeaders {
    $credential = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null | Out-String
    $password = [regex]::Match($credential, '(?m)^password=(.+)$').Groups[1].Value.Trim()
    if (-not $password) { throw 'GitHub authentication unavailable. Sign in through Git Credential Manager.' }
    return @{ Authorization = "Bearer $password"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
}

function Invoke-GitHubBuildApi {
    param([string]$Path, [string]$Method = 'GET', $Body = $null)
    if ($Path -notmatch '^/repos/Yseven004/xiaoqi_app/') { throw 'Unexpected build repository path.' }
    # No retry for mutations: an ambiguous response must not repeat a write.
    $arguments = @{ Uri = "https://api.github.com$Path"; Method = $Method; Headers = (Get-GitHubBuildHeaders); TimeoutSec = 30 }
    if ($null -ne $Body) { $arguments.Body = $Body | ConvertTo-Json -Compress; $arguments.ContentType = 'application/json' }
    Invoke-RestMethod @arguments
}

function Get-MainReleaseCommit {
    param([string]$RepositoryRoot)
    $branch = (& git -C $RepositoryRoot symbolic-ref --quiet --short HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') { throw 'Deployment requires the main branch.' }
    $status = (& git -C $RepositoryRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $status) { throw 'Commit the reviewed changes to main before deployment; the working tree must be clean.' }
    $commit = (& git -C $RepositoryRoot rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Could not identify the main commit.' }
    $remote = (& git -C $RepositoryRoot ls-remote origin refs/heads/main | Out-String).Trim().Split("`t")[0]
    if ($LASTEXITCODE -ne 0 -or $remote -ne $commit) { throw 'Push the reviewed main commit first; local main must match origin/main.' }
    return $commit
}

function Get-ServerBuildArtifact {
    param([string]$RepositoryRoot)
    $commit = Get-MainReleaseCommit -RepositoryRoot $RepositoryRoot
    Write-Host "BUILD_SOURCE branch=main commit=$commit"
    $deadline = (Get-Date).AddMinutes(50)
    $lastState = ''
    $minimumRunId = 0L
    $emptyPolls = 0
    $dispatched = $false
    do {
        $runs = Invoke-GitHubBuildApi -Path "/repos/Yseven004/xiaoqi_app/actions/runs?head_sha=$commit&branch=main"
        $run = @($runs.workflow_runs | Where-Object {
            $_.path -eq '.github/workflows/server-release.yml' -and $_.head_branch -eq 'main' -and $_.head_sha -eq $commit -and
            $_.event -in @('push','workflow_dispatch') -and $_.id -gt $minimumRunId
        } | Sort-Object id -Descending) | Select-Object -First 1
        $needsDispatch = $false
        if ($null -ne $run) {
            $state = "$($run.status)/$($run.conclusion)"
            if ($state -ne $lastState) { Write-Host "BUILD_STATUS $state $($run.html_url)"; $lastState = $state }
            if ($run.status -eq 'completed') {
                if ($run.conclusion -ne 'success') { throw "Off-host build failed: $($run.html_url). Production was not changed." }
                $artifacts = Invoke-GitHubBuildApi -Path "/repos/Yseven004/xiaoqi_app/actions/runs/$($run.id)/artifacts"
                $artifact = @($artifacts.artifacts | Where-Object { $_.name -eq 'server-release' -and -not $_.expired }) | Select-Object -First 1
                if ($null -eq $artifact) {
                    if ($dispatched) { throw 'Rebuilt main has no release artifact.' }
                    $minimumRunId = [long]$run.id
                    $needsDispatch = $true
                } else {
                    # Only the short-lived artifact URL leaves this machine. The Git
                    # credential is never sent to ECS or written to a file.
                    $request = [Net.HttpWebRequest]::Create("https://api.github.com/repos/Yseven004/xiaoqi_app/actions/artifacts/$($artifact.id)/zip")
                    $request.AllowAutoRedirect = $false
                    $request.UserAgent = 'xiaoqi-deploy'
                    $request.Headers['Authorization'] = (Get-GitHubBuildHeaders).Authorization
                    $response = $null
                    try { $response = $request.GetResponse(); $downloadUrl = $response.Headers['Location'] } finally { if ($response) { $response.Dispose() } }
                    $uri = [Uri]$downloadUrl
                    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '(\.blob\.core\.windows\.net|\.actions\.githubusercontent\.com)$') { throw 'Unexpected artifact download host.' }
                    return [pscustomobject]@{ Commit = $commit; RunId = $run.id; RunUrl = $run.html_url; ArtifactId = $artifact.id; DownloadUrl = $downloadUrl }
                }
            }
        } else {
            $emptyPolls++
            $needsDispatch = $emptyPolls -ge 3 -and -not $dispatched
        }
        if ($needsDispatch) {
            if ((Get-MainReleaseCommit -RepositoryRoot $RepositoryRoot) -ne $commit) { throw 'Main changed while waiting; restart deployment with the current reviewed commit.' }
            Invoke-GitHubBuildApi -Path '/repos/Yseven004/xiaoqi_app/actions/workflows/server-release.yml/dispatches' -Method POST -Body @{ref='main'} | Out-Null
            $dispatched = $true
            Write-Host 'BUILD_DISPATCH main: no retained artifact; rebuilding the same main commit.'
        }
        Write-Host 'BUILD_WAIT: GitHub is building/testing; the production service is unchanged.'
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    throw 'Off-host build timed out. Production was not changed.'
}

function Remove-OldBuildArtifacts {
    param([long]$CurrentRunId)
    $list = Invoke-GitHubBuildApi -Path '/repos/Yseven004/xiaoqi_app/actions/artifacts?per_page=100'
    foreach ($artifact in $list.artifacts) {
        if ($artifact.name -eq 'server-release' -and $artifact.workflow_run.id -ne $CurrentRunId) {
            Invoke-GitHubBuildApi -Path "/repos/Yseven004/xiaoqi_app/actions/artifacts/$($artifact.id)" -Method DELETE | Out-Null
        }
    }
}
