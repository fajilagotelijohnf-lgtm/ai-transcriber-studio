param(
    [string]$RuntimeDir,
    [string]$SourceScript,
    [string]$SetupExe,
    [ValidateSet('All','ZeroModels','SingleModel','MultipleModels','MissingEngine','EngineFailure','MalformedJson','MissingModel','CloseDuringFinalization')][string[]]$Cases=@('All'),
    [int]$TimeoutSeconds=300,
    [switch]$SkipPackageIntegrity
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if (-not $RuntimeDir) { $RuntimeDir=Join-Path $root ('test-results\actual install '+[string][char]0x65e5+[char]0x672c+[char]0x8a9e) }
if (-not $SourceScript) { $SourceScript=Join-Path $root 'resources\Transcriber-UI.ps1' }
if (-not $SetupExe) { $SetupExe=Join-Path $root 'build\AI-Transcriber-Setup.exe' }
if ($Cases -contains 'All') { $Cases=@('SingleModel','ZeroModels','MultipleModels','MissingEngine','EngineFailure','MalformedJson','MissingModel','CloseDuringFinalization') }
$results=Join-Path $root ('test-results\recording-smoke-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($results)
$tokens=$null;$parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($SourceScript,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Recording app source has PowerShell parse errors' }
$scriptHash=(Get-FileHash -LiteralPath $SourceScript -Algorithm SHA256).Hash
if (-not $SkipPackageIntegrity) {
    [void][Reflection.Assembly]::LoadFrom($SetupExe)
    $catalog=[AITranscriberInstaller.Catalog]::Embedded()
    if ($scriptHash -ne $catalog.ScriptSha256) { throw 'Recording app source differs from the packaged script; rebuild before running' }
}
$caseResults=New-Object Collections.ArrayList
function Quote-RecordingArgument([string]$Text) { '"'+$Text.Replace('"','\"')+'"' }
foreach ($case in $Cases) {
    $caseDir=Join-Path $results $case
    $install=Join-Path $caseDir ('isolated install '+[string][char]0x65e5+[char]0x672c+[char]0x8a9e)
    $output=Join-Path $caseDir 'output'
    [void][IO.Directory]::CreateDirectory($install)
    [void][IO.Directory]::CreateDirectory($output)
    # Link immutable large runtime/model assets, never mutate the existing install.
    $assets=@(Get-ChildItem -LiteralPath $RuntimeDir -File | Where-Object { $_.Extension -eq '.dll' -or $_.Name -in @('whisper-cli.exe','ffmpeg.exe') })
    if ($case -ne 'ZeroModels') { $assets+=Get-Item -LiteralPath (Join-Path $RuntimeDir 'ggml-small.bin') }
    if ($case -eq 'MultipleModels') { $assets+=Get-Item -LiteralPath (Join-Path $RuntimeDir 'ggml-medium.bin') }
    foreach ($asset in $assets) {
        $target=Join-Path $install $asset.Name
        try { New-Item -ItemType HardLink -Path $target -Target $asset.FullName -ErrorAction Stop | Out-Null }
        catch { Copy-Item -LiteralPath $asset.FullName -Destination $target }
    }
    Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $install 'Transcriber-UI.ps1')
    Copy-Item -LiteralPath $SetupExe -Destination (Join-Path $install 'AITranscriber.exe')
    Copy-Item -LiteralPath (Join-Path $root 'tests\assets\jfk.wav') -Destination (Join-Path $output 'jfk.wav')
    $appdata=Join-Path $caseDir 'isolated-appdata'
    $settings=Join-Path $appdata 'AITranscriberStudio'
    [void][IO.Directory]::CreateDirectory($settings)
    @{UseSystem=$false;UseMic=$false;FileModel='ggml-small.bin';LiveModel='ggml-small.bin';FinalModel='ggml-small.bin';SaveFolder=$output} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settings 'settings.json') -Encoding UTF8
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File '+(Quote-RecordingArgument (Join-Path $PSScriptRoot 'Recording-Smoke-Harness.ps1'))+' -InstallDir '+(Quote-RecordingArgument $install)+' -ResultDir '+(Quote-RecordingArgument $output)+' -Case '+$case
    if (-not $SkipPackageIntegrity) { $arguments+=' -CheckDesktopIdentity' }
    $info=New-Object Diagnostics.ProcessStartInfo($ps,$arguments)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden';$info.WorkingDirectory=$install
    $info.EnvironmentVariables['APPDATA']=$appdata
    $info.EnvironmentVariables['PATH']=$install+';'+$info.EnvironmentVariables['PATH']
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    $caseResult=$null
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(1000)) {
            if ($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                # Terminate only this harness and its own children, never name-match
                # unrelated applications. /T includes a hung native engine/modal.
                & (Join-Path $env:WINDIR 'System32\taskkill.exe') /PID $process.Id /T /F | Out-Null
                [void]$process.WaitForExit(5000)
                throw ('Recording UI timed out after '+$TimeoutSeconds+' seconds')
            }
        }
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $caseDir 'stdout.log')
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $caseDir 'stderr.log')
        $caseResult=Get-Content -LiteralPath (Join-Path $output 'recording-ui-result.json') -Raw | ConvertFrom-Json
        if ($process.ExitCode -ne 0) { $caseResult.Success=$false }
        if ((Get-FileHash -LiteralPath (Join-Path $install 'Transcriber-UI.ps1') -Algorithm SHA256).Hash -ne $scriptHash) { throw 'Isolated app script changed during the smoke test' }
    } catch { $caseResult=[pscustomobject]@{Success=$false;Case=$case;Message=$_.Exception.Message} }
    finally { $process.Dispose() }
    [void]$caseResults.Add($caseResult)
    Write-Output (('{0} {1}: {2}' -f $(if ($caseResult.Success) {'PASS'} else {'FAIL'}),$case,$caseResult.Message))
}
$summary=[pscustomobject]@{Success=(@($caseResults | Where-Object {-not $_.Success}).Count -eq 0);ResultDirectory=$results;ScriptSha256=$scriptHash;PackageIntegrityChecked=(-not $SkipPackageIntegrity);Cases=@($caseResults)}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $results 'recording-smoke-summary.json') -Encoding UTF8
Write-Output ('Results: '+$results)
if (-not $summary.Success) { exit 1 }
