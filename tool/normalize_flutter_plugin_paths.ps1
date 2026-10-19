param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ProjectRoot = $ProjectRoot.TrimEnd('\', '/')
$metadataPath = Join-Path $ProjectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $metadataPath)) {
    exit 0
}

try {
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
                $normalized = $plugin.path.Replace('\\', '\')
                if ($normalized -ne $plugin.path) {
                    $plugin.path = $normalized
                    $changed = $true
                }
            }
        }
    }

    if ($changed) {
        $json = $metadata | ConvertTo-Json -Compress -Depth 20
        Set-Content -LiteralPath $metadataPath -Value $json -NoNewline -Encoding utf8NoBOM
        Write-Host 'Normalized Flutter plugin paths for Windows Gradle.'
    }
}
catch {
    Write-Warning ("Could not normalize Flutter plugin paths: {0}" -f $_.Exception.Message)
}
