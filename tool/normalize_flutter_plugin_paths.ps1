param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ProjectRoot = $ProjectRoot.TrimEnd('\', '/')
$metadataPath = Join-Path $ProjectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $metadataPath)) {
    exit 0
}

try {
    $cacheAlias = Join-Path $env:LOCALAPPDATA 'Pub\CacheD'
    $cacheItem = Get-Item -LiteralPath $cacheAlias -ErrorAction SilentlyContinue
    $cacheTarget = if ($cacheItem -and $cacheItem.Target) { [string]@($cacheItem.Target)[0] } else { $cacheAlias }
    function Resolve-PackagePath([string]$Path) {
        $normalized = $Path.Replace('\\', '\')
        if ($normalized.StartsWith($cacheAlias, [StringComparison]::OrdinalIgnoreCase)) {
            return $cacheTarget + $normalized.Substring($cacheAlias.Length)
        }
        return $normalized
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $changed = $false
    $metadataBytes = [System.IO.File]::ReadAllBytes($metadataPath)
    if ($metadataBytes.Length -ge 3 -and
        $metadataBytes[0] -eq 0xEF -and
        $metadataBytes[1] -eq 0xBB -and
        $metadataBytes[2] -eq 0xBF) {
        $changed = $true
    }

    foreach ($platform in @('android', 'ios', 'macos', 'linux', 'windows', 'web')) {
        $plugins = $metadata.plugins.$platform
        if ($null -eq $plugins) {
            continue
        }

        foreach ($plugin in $plugins) {
            if ($plugin.path) {
                $normalized = Resolve-PackagePath $plugin.path
                if ($normalized -ne $plugin.path) {
                    $plugin.path = $normalized
                    $changed = $true
                }
            }
        }
    }

    $packagePath = Join-Path $ProjectRoot '.dart_tool\package_config.json'
    if (Test-Path -LiteralPath $packagePath) {
        $packageConfig = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
        $packageChanged = $false
        foreach ($package in $packageConfig.packages) {
            if ($package.rootUri.StartsWith('file:')) {
                $original = ([Uri]$package.rootUri).LocalPath
                $resolved = Resolve-PackagePath $original
                if ($resolved -ne $original) {
                    $package.rootUri = ([Uri]($resolved.TrimEnd('\', '/') + '\')).AbsoluteUri
                    $packageChanged = $true
                }
            }
        }
        if ($packageChanged) {
            [IO.File]::WriteAllText($packagePath, ($packageConfig | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        }
    }
    if ($changed) {
        $json = $metadata | ConvertTo-Json -Compress -Depth 20
        [System.IO.File]::WriteAllText($metadataPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host 'Normalized Flutter plugin paths for Windows Gradle.'
    }
}
catch {
    Write-Warning ("Could not normalize Flutter plugin paths: {0}" -f $_.Exception.Message)
}
