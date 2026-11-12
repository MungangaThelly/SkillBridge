$ErrorActionPreference = 'Stop'

$workspace = $PSScriptRoot
$buildDir = Join-Path $workspace 'ebin'
$dataDir = Join-Path $workspace 'data'

New-Item -ItemType Directory -Force -Path $buildDir, $dataDir | Out-Null

$sourceFiles = @(
    'src\skillbridge_store.erl',
    'src\skillbridge_json.erl',
    'src\skillbridge_http.erl',
    'src\skillbridge_sup.erl',
    'src\skillbridge_app.erl'
) | ForEach-Object { Join-Path $workspace $_ }

& erlc -o $buildDir @sourceFiles
if ($LASTEXITCODE -ne 0) {
    throw "Erlang compilation failed with exit code $LASTEXITCODE."
}

Copy-Item -LiteralPath (Join-Path $workspace 'src\skillbridge.app.src') `
    -Destination (Join-Path $buildDir 'skillbridge.app') -Force

$oldErlFlags = $env:ERL_AFLAGS
$oldDataPath = $env:SKILLBRIDGE_DATA
try {
    $env:ERL_AFLAGS = '-kernel inet_gethost_native true'
    $env:SKILLBRIDGE_DATA = $dataDir
    Write-Host 'SkillBridge is starting at http://localhost:8080. Press Ctrl+C to stop it.'
    & erl -pa $buildDir -noshell -eval 'application:ensure_all_started(skillbridge), timer:sleep(infinity).'
    if ($LASTEXITCODE -ne 0) {
        throw "SkillBridge exited with code $LASTEXITCODE."
    }
} finally {
    $env:ERL_AFLAGS = $oldErlFlags
    $env:SKILLBRIDGE_DATA = $oldDataPath
}
