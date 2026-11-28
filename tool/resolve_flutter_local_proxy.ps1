$ErrorActionPreference = 'SilentlyContinue'

# Explicit proxy environment variables take precedence. Their JVM configuration
# remains the caller's responsibility; this helper only discovers the enabled
# Windows loopback proxy used by the project's Flutter wrapper.
if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy) {
    exit 0
}

if ($env:OS -ne 'Windows_NT') {
    exit 0
}

$settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if (-not $settings.ProxyEnable -or -not $settings.ProxyServer) {
    exit 0
}

$server = [string]$settings.ProxyServer
if ($server -match '(?:^|;)https=([^;]+)') {
    $server = $Matches[1]
} elseif ($server -match '(?:^|;)http=([^;]+)') {
    $server = $Matches[1]
} elseif ($server.Contains('=')) {
    exit 0
}

if ($server -match '^(?:http://)?(?<host>127\.0\.0\.1|localhost):(?<port>[0-9]{1,5})$') {
    $proxyHost = $Matches.host
    $port = [int]$Matches.port
    if ($port -ge 1 -and $port -le 65535) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connection = $client.ConnectAsync($proxyHost, $port)
            if ($connection.Wait(500) -and $client.Connected) {
                '{0} {1}' -f $proxyHost, $port
            }
        } catch {
            # An enabled Windows proxy can outlive the app listening on it.
            # Leave Flutter's proxy variables unset when that local port is down.
        } finally {
            $client.Dispose()
        }
    }
}
