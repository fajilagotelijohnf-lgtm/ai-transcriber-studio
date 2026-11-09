param([switch]$Test)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$catalogPath = Join-Path $root 'resources\dependencies.json'
$catalogData = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$scriptHash = (Get-FileHash -LiteralPath (Join-Path $root 'resources\Transcriber-UI.ps1') -Algorithm SHA256).Hash
if ($catalogData.ScriptSha256 -ne $scriptHash) {
    $catalogData.ScriptSha256 = $scriptHash
    [IO.File]::WriteAllText($catalogPath, ($catalogData | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework compiler not found' }
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.cs' | ForEach-Object FullName)
$common = @('/nologo','/platform:x64','/optimize+','/utf8output','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Net.Http.dll','/reference:System.Runtime.Serialization.dll','/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll','/reference:System.Management.dll')
$common += '/reference:Microsoft.CSharp.dll'
$common += '/win32manifest:' + (Join-Path $root 'resources\app.manifest')
$common += '/win32icon:' + (Join-Path $root 'resources\Transcriber.ico')
foreach ($entry in @(@('Transcriber-UI.ps1','Transcriber'),@('dependencies.json','Catalog'),@('THIRD-PARTY-NOTICES.md','Notices'),@('Whisper-LICENSE.txt','WhisperLicense'))) {
    $common += '/resource:' + (Join-Path $root ('resources\' + $entry[0])) + ',Payload.' + $entry[1]
}
& $compiler @common '/target:winexe' ('/out:' + (Join-Path $build 'AI-Transcriber-Setup.exe')) @sources
if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
$testSources = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.cs' | ForEach-Object FullName)
& $compiler @common '/target:exe' '/main:InstallerTests' ('/out:' + (Join-Path $build 'InstallerTests.exe')) @sources @testSources
if ($LASTEXITCODE -ne 0) { throw 'Test build failed' }
if ($Test) { & (Join-Path $build 'InstallerTests.exe') catalog; if ($LASTEXITCODE -ne 0) { throw 'Catalog tests failed' } }
'Build complete'
