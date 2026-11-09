$ErrorActionPreference='Continue'
$root=Split-Path -Parent $PSScriptRoot
$path=Join-Path $root 'resources\Transcriber-UI.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'App parse errors'}
foreach($name in @('Wait-ForProcess','Format-Transcript','Save-Transcript','Import-AppSettings','Export-AppSettings','New-OutputJob','Close-OutputJob')){
 $node=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -eq $name|Select-Object -First 1
 . ([scriptblock]::Create($node.Extent.Text))
}
Add-Type -AssemblyName System.Windows.Forms
$script:uiBusy=$false;$script:cancelRequested=$false
$script:pass=0;$script:fail=0
function Check($name,[scriptblock]$test){try{&$test;$script:pass++;Write-Output "PASS $name"}catch{$script:fail++;Write-Output "FAIL $name : $($_.Exception.Message)"}}
function Require($value,$message){if(-not $value){throw $message}}
function MustThrow([scriptblock]$body){$threw=$false;try{&$body|Out-Null}catch{$threw=$true};Require $threw 'Expected a terminating error'}
$fixture=Join-Path $root ('test-results\app-core-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
Check 'main UI exposes model download button' {Require (([IO.File]::ReadAllText($path)).Contains('$btnManageModels =')) 'Missing Download / Manage Models button'}
$runner=[pscustomobject]@{HasExited=$true;ExitCode=7;Killed=$false}
$runner|Add-Member ScriptMethod DrainOutput {return ''};$runner|Add-Member ScriptMethod DrainError {return 'engine failed'};$runner|Add-Member ScriptMethod Kill {$this.Killed=$true;$this.HasExited=$true}
Check 'nonzero engine exit cannot report success' {MustThrow {Wait-ForProcess -Runner $runner}}
Check 'null engine runner rejected' {MustThrow {Wait-ForProcess -Runner $null}}
$hanging=[pscustomobject]@{HasExited=$false;ExitCode=0;Killed=$false}
$hanging|Add-Member ScriptMethod DrainOutput {return ''};$hanging|Add-Member ScriptMethod DrainError {return ''};$hanging|Add-Member ScriptMethod Kill {$this.Killed=$true;$this.HasExited=$true}
Check 'hung chunk wait has bounded timeout' {Require ((Get-Command Wait-ForProcess).Parameters.ContainsKey('TimeoutSeconds')) 'Missing timeout support';MustThrow {Wait-ForProcess -Runner $hanging -TimeoutSeconds 0.05};Require $hanging.Killed 'Timed-out child not killed'}
$bad=Join-Path $fixture 'bad.json';[IO.File]::WriteAllText($bad,'{bad json')
Check 'malformed JSON fails instead of empty success' {MustThrow {Format-Transcript -JsonPath $bad}}
$shape=Join-Path $fixture 'wrong.json';[IO.File]::WriteAllText($shape,'{"different":true}')
Check 'wrong JSON schema is rejected' {MustThrow {Format-Transcript -JsonPath $shape}}
$result=[pscustomobject]@{Header=@('test');Lines=@('one');AvgConfidence=1;LowConfidence=0;Corrected=0}
Check 'transcript write failure is terminating' {MustThrow {Save-Transcript -Result $result -Path (Join-Path $fixture 'missing\out.txt')}}
$script:Settings=@{UseSystem=$false;UseMic=$false;FileModel='';LiveModel='';FinalModel='';SaveFolder='';Vocabulary='';FileVocabulary=''}
$script:SettingsPath=Join-Path $fixture 'settings.json';[IO.File]::WriteAllText($script:SettingsPath,'{"UseMic":"false","UseSystem":"true"}')
Check 'string booleans cannot silently enable audio' {Import-AppSettings;Require (-not $script:Settings.UseMic -and -not $script:Settings.UseSystem) 'Untrusted setting type accepted'}
Check 'settings survive atomic repeated saves' {Export-AppSettings;Export-AppSettings;$s=Get-Content -LiteralPath $SettingsPath -Raw|ConvertFrom-Json;Require ($s.UseMic -eq $false) 'Settings roundtrip failed';Require (@(Get-ChildItem -LiteralPath $fixture -Filter '*.tmp').Count -eq 0) 'Temporary files remained'}
$existing=Join-Path $fixture 'existing.txt';[IO.File]::WriteAllText($existing,'preserved')
Check 'transcript cannot overwrite prior output' {MustThrow {Save-Transcript -Result $result -Path $existing};Require ([IO.File]::ReadAllText($existing) -eq 'preserved') 'Prior output overwritten'}
Check 'concurrent output reservations use different names' {$a=New-OutputJob -Directory $fixture -BaseName 'job';$b=$null;try{$b=New-OutputJob -Directory $fixture -BaseName 'job';Require ($a.OutBase -ne $b.OutBase) 'Output collision'}finally{Close-OutputJob $a;Close-OutputJob $b}}
Check 'media conversion disallows network protocols' {$source=[IO.File]::ReadAllText($path);Require ($source.Contains("'-protocol_whitelist', 'file,pipe'")) 'Missing local-only FFmpeg policy'}
Write-Output "APP CORE RESULT $script:pass passed, $script:fail failed"
if($script:fail){exit 1}
