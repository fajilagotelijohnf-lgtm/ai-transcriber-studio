param([string]$InstallDir,[string]$SourcePackage)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if (-not $InstallDir) { $InstallDir=Join-Path $root ('test-results\actual install '+[string][char]0x65e5+[char]0x672c+[char]0x8a9e) }
$results=Join-Path $root ('test-results\app-smoke-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $results | Out-Null
$sample=Join-Path $root 'tests\assets\jfk.wav'
Copy-Item -LiteralPath $sample -Destination (Join-Path $results 'jfk.wav') -Force
$tokens=$null;$parseErrors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $InstallDir 'Transcriber-UI.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'PowerShell parse failed' }
[void][Reflection.Assembly]::LoadFrom((Join-Path $root 'build\AI-Transcriber-Setup.exe'))
$catalog=[AITranscriberInstaller.Catalog]::Embedded()
$hash=(Get-FileHash -LiteralPath (Join-Path $InstallDir 'Transcriber-UI.ps1') -Algorithm SHA256).Hash
if ($hash -ne $catalog.ScriptSha256) { throw 'Installed script differs from the packaged script SHA256' }
if ($SourcePackage) {
    $sourceHash=(Get-FileHash -LiteralPath (Join-Path $SourcePackage 'Transcriber-UI.ps1') -Algorithm SHA256).Hash
    if ($sourceHash -ne $catalog.OriginalScriptSha256) { throw 'Original source provenance SHA256 changed' }
}
[AITranscriberInstaller.NativeRuntime]::Check($InstallDir)
$appdata=Join-Path $results 'isolated-appdata'
$settingsDir=Join-Path $appdata 'AITranscriberStudio'
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
@{UseSystem=$false;UseMic=$false;FileModel='ggml-small.bin';LiveModel='ggml-small.bin';FinalModel='ggml-medium.bin';SaveFolder=$results} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settingsDir 'settings.json') -Encoding UTF8
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argsText='-NoProfile -STA -ExecutionPolicy Bypass -File '+[AITranscriberInstaller.WindowsIntegration]::Quote((Join-Path $PSScriptRoot 'App-Smoke-Harness.ps1'))+' -InstallDir '+[AITranscriberInstaller.WindowsIntegration]::Quote($InstallDir)+' -ResultDir '+[AITranscriberInstaller.WindowsIntegration]::Quote($results)
$info=New-Object System.Diagnostics.ProcessStartInfo($ps,$argsText)
$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden';$info.WorkingDirectory=$InstallDir
$info.EnvironmentVariables['APPDATA']=$appdata
$info.EnvironmentVariables['PATH']=$InstallDir+';'+$info.EnvironmentVariables['PATH']
$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$process=New-Object System.Diagnostics.Process
$process.StartInfo=$info
try {
    [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) {
        if ($deadline.Elapsed.TotalSeconds -gt 300) { $process.Kill();[void]$process.WaitForExit(5000);throw ('App UI smoke test timed out. Results: '+$results) }
    }
    $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $results 'stdout.log')
    $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $results 'stderr.log')
    $uiResult=Get-Content -LiteralPath (Join-Path $results 'app-ui-result.json') -Raw | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or -not $uiResult.Success) { throw ($uiResult.Message+' Results: '+$results) }
    if ((Get-FileHash -LiteralPath (Join-Path $InstallDir 'Transcriber-UI.ps1') -Algorithm SHA256).Hash -ne $catalog.ScriptSha256) { throw 'Installed script changed during smoke test' }
    $uiResult | Add-Member -NotePropertyName PackagedScriptSha256 -NotePropertyValue $hash
    $uiResult | Add-Member -NotePropertyName OriginalScriptSha256 -NotePropertyValue $catalog.OriginalScriptSha256
    $uiResult | Add-Member -NotePropertyName ResultDirectory -NotePropertyValue $results
    $uiResult | ConvertTo-Json -Depth 6
    'PASS packaged script integrity, original source provenance, model-manager integration, deferred refresh and repeated file transcription'
} finally { $process.Dispose() }
