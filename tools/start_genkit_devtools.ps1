$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $repoRoot 'xiaoqi_harness\genkit_server'
$envFile = Join-Path $repoRoot 'private\models.local.env'
$dataRoot = Join-Path $repoRoot '.codex-artifacts\genkit-devtools\data'

if (-not (Test-Path -LiteralPath $serverRoot -PathType Container)) {
    throw 'Genkit server package directory was not found.'
}

if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($rawLine in Get-Content -LiteralPath $envFile) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
# The API's Genkit instance is started by `genkit start` with dev telemetry,
# and this process also registers the single DevTools Flow below. Keep the
# per-request Agent Genkit instances out of the CLI runtime list: eval:flow
# resolves actions from the most recently registered runtime, so one runtime
# per Agent request makes the Flow disappear from evaluation.
$env:XIAOQI_CAPTURE_TRACES = '0'
$env:XIAOQI_DATA_DIR = $dataRoot
$env:XIAOQI_DEVTOOLS_DATA_DIR = $dataRoot
$env:XIAOQI_DEVTOOLS_API_PORT = '8180'

Push-Location $serverRoot
try {
    $busyPort = Get-NetTCPConnection -State Listen -LocalPort 4000 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($busyPort) {
        throw 'Port 4000 is already in use. Stop the current Genkit Developer UI before starting this harness.'
    }

    $genkitCommand = Get-Command genkit -ErrorAction SilentlyContinue
    if ($genkitCommand) {
        & $genkitCommand.Source --non-interactive start --port 4000 --host 127.0.0.1 -- dart run tool\genkit_devtools_agent.dart
    }
    else {
        $npmCache = (& npm config get cache --silent 2>$null | Select-Object -Last 1).Trim()
        $npxRoot = Join-Path $npmCache '_npx'
        $cachedCli = Get-ChildItem -LiteralPath $npxRoot -Filter 'genkit.js' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\node_modules\\genkit-cli\\dist\\bin\\genkit\.js$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $cachedCli) {
            throw 'Genkit CLI was not found in PATH or the local npm cache. No package was installed.'
        }
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeCommand) {
            throw 'Node.js is required to run the cached Genkit CLI.'
        }
        & $nodeCommand.Source $cachedCli.FullName --non-interactive start --port 4000 --host 127.0.0.1 -- dart run tool\genkit_devtools_agent.dart
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Genkit Developer UI exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
