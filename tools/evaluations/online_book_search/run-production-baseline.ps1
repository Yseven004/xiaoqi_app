param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$OutputPath,
    [string[]]$CaseId
)
$ErrorActionPreference = 'Stop'
$Region = 'cn-hongkong'
$Profile = 'xiaoqi-remote-deploy'
$InstanceId = 'i-j6cdji1nji415swaliji'
$Endpoint = 'ecs.cn-hongkong.aliyuncs.com'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$deploy = Join-Path $repo 'xiaoqi_harness/deploy/deploy_current.ps1'
$functions = @('Get-EcsLocalProxy', 'Invoke-AliyunJson', 'Get-OptionalField',
    'Test-EcsConnection', 'Wait-RemoteCommand', 'Invoke-RemoteCommand')
$ast = [System.Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$null, [ref]$null)
foreach ($node in $ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $functions
}, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}

function Compress-Utf8([string]$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $stream = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Compress, $true)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Dispose()
    $compressed = [Convert]::ToBase64String($stream.ToArray())
    $stream.Dispose()
    return $compressed
}

$dataset = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'cases.json')
$cases = @($dataset | ConvertFrom-Json)
if ($CaseId) {
    $selected = @($cases | Where-Object { $_.id -in $CaseId })
    if ($selected.Count -ne $CaseId.Count) { throw 'Unknown or duplicate evaluation case ID' }
    foreach ($row in $selected | Where-Object { $_.after }) {
        if ($row.after -notin $CaseId) { throw "Case $($row.id) also requires $($row.after)" }
    }
    $cases = $selected
    $dataset = ConvertTo-Json -InputObject $cases -Depth 8 -Compress
}
$source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'evaluate.py')
$data = Compress-Utf8 $dataset
$code = Compress-Utf8 $source
$remoteFile = '/tmp/xiaoqi-book-eval-' + [guid]::NewGuid().ToString('N')
$command = @'
set -eu
umask 077
dir=/opt/xiaoqi-single-server
app=$(docker ps --filter label=com.docker.compose.service=app --filter label=com.docker.compose.project=xiaoqi-single-server --format '{{.ID}}')
test -n "$app"
image=$(docker inspect --format '{{.Image}}' "$app")
python3 - "$dir/current/.xiaoqi-artifact.json" "__COMMIT__" "$image" <<'MANIFEST'
import json,sys
with open(sys.argv[1]) as source:
    manifest=json.load(source)
assert manifest['source_commit']==sys.argv[2], 'Unexpected active release commit'
assert next(i for i in manifest['images'] if i['name']=='xiaoqi-genkit-server')['id']==sys.argv[3], 'Unexpected active app image'
MANIFEST
docker run -i --rm --pull never --memory 640m --cpus=1 --read-only --tmpfs /tmp:rw,size=96m --env-file "$dir/config/single-server.env" --env XIAOQI_DATA_DIR=/tmp/book-eval --env XIAOQI_CAPTURE_TRACES=0 --entrypoint python3 "$image" - "__COMMIT__" "$image" > "__REPORT__" <<'PY'
import base64,gzip,json,sys
exec(gzip.decompress(base64.b64decode('__CODE__')).decode())
main(json.loads(gzip.decompress(base64.b64decode('__DATA__'))), {'commit': sys.argv[1], 'image': sys.argv[2]})
PY
wc -c < "__REPORT__"
'@
$command = $command.Replace('__COMMIT__', $ExpectedCommit).Replace('__REPORT__', $remoteFile).
    Replace('__DATA__', $data).Replace('__CODE__', $code)
Test-EcsConnection
Write-Host "Running isolated evaluation on $ExpectedCommit"
$length = [int](Invoke-RemoteCommand -Script $command -TimeoutSeconds 1500)
if ($length -lt 100 -or $length -gt 100000) { throw "Unexpected evaluation report size $length" }
$bytes = [IO.MemoryStream]::new()
for ($offset = 0; $offset -lt $length; $offset += 3900) {
    $script = "dd if='$remoteFile' bs=3900 skip=$([int]($offset / 3900)) count=1 status=none | base64 -w0"
    $chunk = [Convert]::FromBase64String((Invoke-RemoteCommand -Script $script -TimeoutSeconds 45))
    $bytes.Write($chunk, 0, $chunk.Length)
}
if ($bytes.Length -ne $length) { throw 'Incomplete evaluation report' }
$lines = [Text.Encoding]::UTF8.GetString($bytes.ToArray()) -split "`n"
$packed = ($lines | Where-Object { $_.StartsWith('REPORT ') } | ForEach-Object { $_.Substring(7) }) -join ''
$stream = [IO.MemoryStream]::new([Convert]::FromBase64String($packed))
$gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
$reader = [IO.StreamReader]::new($gzip)
$report = $reader.ReadToEnd()
$reader.Dispose()
$result = $report | ConvertFrom-Json
$count = $cases.Count
if ($result.rows.Count -ne $count -or $result.release.commit -ne $ExpectedCommit) {
    throw 'Evaluation report identity or case count mismatch'
}
[IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath), $report)
Invoke-RemoteCommand -Script "rm -f -- '$remoteFile'" -TimeoutSeconds 45 | Out-Null
$lines | Where-Object { $_ -and -not $_.StartsWith('REPORT ') }
