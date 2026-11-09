$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=[IO.File]::ReadAllText((Join-Path $root 'resources\Transcriber-UI.ps1'))
$match=[regex]::Match($source,"Add-Type -TypeDefinition @'\r?\n([\s\S]*?)\r?\n'@")
Add-Type -TypeDefinition $match.Groups[1].Value
Add-Type -TypeDefinition 'public class AudioGate { public static System.Threading.ManualResetEvent Gate=new System.Threading.ManualResetEvent(false); public static System.Threading.Thread Start(){Gate.Reset();var t=new System.Threading.Thread(delegate(){Gate.WaitOne();});t.IsBackground=true;t.Start();return t;} }'
$type=[AudioEngine.CoreAudio];$flags=[Reflection.BindingFlags]'Static,NonPublic'
function Set-Field($name,$value){$type.GetField($name,$flags).SetValue($null,$value)}
function Get-Field($name){$type.GetField($name,$flags).GetValue($null)}
$pass=0;$fail=0
function Check($name,[scriptblock]$body){try{&$body;$script:pass++;"PASS $name"}catch{$script:fail++;"FAIL $name : $($_.Exception.Message)"}}
$fixture=Join-Path $root ('test-results\audio-core-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
Check 'worker failure clears state and finalizes WAV without hardware' {
 $path=Join-Path $fixture 'worker.wav';$wav=[IO.File]::Open($path,'Create','ReadWrite','Read');$wav.Write((New-Object byte[] 44),0,44)
 Set-Field '_wav' $wav;Set-Field '_dataBytes' ([long]0);Set-Field '_recRunning' $true;Set-Field '_recSys' $false;Set-Field '_recMic' $false
 try{$type.GetMethod('RecordWorker',$flags).Invoke($null,@());if([AudioEngine.CoreAudio]::IsRecording){throw 'Failed worker still marked running'};if([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path),0,4) -ne 'RIFF'){throw 'WAV header was not finalized'}}finally{[AudioEngine.CoreAudio]::StopRecording();$wav.Dispose();Set-Field '_wav' $null;Set-Field '_recRunning' $false}
}
Check 'mix format pointer has ownership cleanup' {if(-not $source.Contains('Marshal.FreeCoTaskMem(pFmt)')){throw 'Unmanaged mix format allocation leaks'}}
Check 'previous worker blocks recording restart' {
 $thread=[AudioGate]::Start();Set-Field '_recThread' $thread;Set-Field '_recRunning' $false
 try{$threw=$false;try{[AudioEngine.CoreAudio]::StartRecording('','',$false,$false,1,1,(Join-Path $fixture 'new.wav'))}catch{$threw=$true};if(-not $threw){throw 'A previous worker was replaced while still alive'}}finally{[void][AudioGate]::Gate.Set();[void]$thread.Join(1000);[AudioEngine.CoreAudio]::StopRecording();Set-Field '_recThread' $null}
}
Check 'audio mixer disabled and silent cases' {$method=$type.GetMethod('PlanMix',$flags);foreach($case in @(@(-1,-1,$true,$true,0),@(100,-1,$false,$true,100),@(100,0,$false,$true,100),@(100,0,$false,$false,0),@(100,50,$false,$false,50))){$actual=$method.Invoke($null,@([int]$case[0],[int]$case[1],[bool]$case[2],[bool]$case[3]));if($actual -ne $case[4]){throw 'Unexpected mix count'}}}
Check 'noisy child output is bounded and includes its final diagnostics' {
 $runner=New-Object AudioEngine.ProcRunner
 try {
  $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $command='for($i=0;$i -lt 12000;$i++){[Console]::WriteLine(("x"*100))};[Console]::Error.WriteLine("FINAL_ERROR_MARKER");[Console]::WriteLine("FINAL_OUTPUT_MARKER")'
  $args='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  if(-not $runner.Start($exe,$args,$fixture,$true)){throw $runner.Error}
  $clock=[Diagnostics.Stopwatch]::StartNew();while(-not $runner.HasExited){if($clock.Elapsed.TotalSeconds -gt 20){$runner.Kill();throw 'Noisy process timed out'};Start-Sleep -Milliseconds 20}
  $out=$runner.DrainOutput();$err=$runner.DrainError()
  if($out.Length -gt 262146 -or $out -notmatch 'FINAL_OUTPUT_MARKER' -or $err -notmatch 'FINAL_ERROR_MARKER'){throw 'Unbounded output or lost terminal diagnostics'}
 }finally{$runner.Dispose()}
}
"AUDIO CORE RESULT $pass passed, $fail failed"
if($fail){exit 1}
